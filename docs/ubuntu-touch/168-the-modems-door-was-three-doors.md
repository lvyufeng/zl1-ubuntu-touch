# 168 — modem 的门是三扇，每一扇都独立致命：**ofono 现在枚举出两个 modem**

**日期**: 2026-09-25
**状态**: **在设备上做完并装上**（同一次开机 `2fbf9f8e`，没有重启、没有写任何分区、没有打开任何块设备、
容器没有停过）。`org.ofono.Manager.GetModems` 从这台机器有史以来的 `a(oa{sv}) 0` 变成
**`a(oa{sv}) 2`**：`/ril_0`、`/ril_1`，两个都带**真实的 modem 固件版本**（`MPSS.TH.2.0.c1.9.1-00044`）
和**真实的 IMEI**（`861579037654648` / `861579037654655`）。

**接续**: [`120`](120-the-subsystem-nobody-has-looked-at.md)（modem：唯一一个一次真机读数都没有的子系统，
以及那次固件路径的读数）、[`43`](43-binder-does-not-cross-a-pid-namespace.md)、
[`55`](55-the-bridge-libraries-built-and-hwbinder-does-not-cross-pid-namespaces-either.md)、
[`60`](60-sensorfwd-was-the-third-service-behind-the-same-wall.md)、
[`62`](62-bluetooth-two-things-that-read-from-the-wrong-place.md)（同一堵墙的前三次；这是**第五个**服务）、
[`149`](149-lshal-columns-have-a-definition.md)（`lshal` 的 `R` 列只在第一张表里有意义）。

原始输出: [`evidence/ofono-binder-2026-09-25.log`](evidence/ofono-binder-2026-09-25.log)。
安装/回滚/查看: `scripts/hybris-shims/install-ofono-binder.sh --install | --remove | --status`。

---

## 1. 一句话结论

| 问题 | 答案 |
|---|---|
| modem 之前为什么"不能用"？ | **不是没有 modem。** 子系统 `ONLINE`、固件在 `/vendor/firmware_mnt/image`、`rild` 在跑、Android 的 radio HAL 在容器里是**活的**（`lshal` 第一张表：`Y android.hardware.radio@1.1::IRadio/slot1` 和 `/slot2`）。缺的是 ofono 能走到它的**三件事**，每一件都单独致命，而且**每一件都不出声**。 |
| 门一：插件 | 跑着的 ofonod 命令行里写着 `-P ...,binder`——**binder 插件被关掉了**。关它的不是人：`ofonod-wrapper` 用 `device-info get OfonoPlugin` 选插件，而这个命令在这台机器上**对每一个键都 segfault（rc=139）**，于是永远走 `else` 分支：关 binder、留 ril。而 ril 插件要的 `socket=/dev/socket/rild` **这个 Android 根本不创建**（`rild.legacy.rc` 里没有 `socket rild` 这一行）。设备自己的 journal 里，旧 ofono 说过 11 次：`[grilio-socket] ERROR: Can't connect to RILD: No such file or directory`。 |
| 门二：命名空间 | 同一条 ofonod 命令行，只换命名空间：宿主里 `[gbinder] WARNING: registerForNotifications(...) failed`；容器里 `Connected to android.hardware.radio@1.1::IRadio/slot1` 和 `/slot2`。**同一堵墙的第五次**，修法一样：走 `zl1-ns-exec`。 |
| 门三：配置 | 插件和命名空间都对之后，它还是要 `/etc/ofono/binder.conf`，否则 `Missing path for slot slot1`——`path`（ofono 的 modem 对象路径）必须逐 slot 给出。另外插件的 `radioInterface` **默认 1.2**，而这台机器只注册到 **1.1**。 |
| 装上了吗？ | 装上了，**不用重启**：一个 drop-in（`ExecStart` 换成 `zl1-ns-exec` + 正确的 `-P`，`BindPaths=` 给 ofonod 一个私有的 `/etc/ofono`）+ `/userdata/zl1-ofono/etc/binder.conf`。`systemctl restart ofono` 之后 system bus 上 `GetModems` 就是两个 modem。 |
| SIM 呢？ | **modem 报"没有卡"，而且是它自己说的**：`getIccCardStatusResponse` 回 `card_state=0`（HIDL `ABSENT`）、`num_apps=0`，两个卡槽各一次。这条读数**证明了整条路径是通的**（请求进、`CardStatus` 回、ofono 状态出）；它分不出"空卡槽"和"有卡但 modem 认不出来"——那要人看一眼卡槽（见 §6）。 |

---

## 2. 门一：错的插件，而且这个错是**一次 segfault** 选的

跑着的 ofonod（**修之前**）：

```
/usr/sbin/ofonod -P stktest,sap,udev,dun,smart,hfp,hfp_bluez5,provision,binder --nodetach
```

`-P` 是"不加载"。`binder` 在里面，所以 binder 插件是关的。从 `/proc/<pid>/maps` 读它**实际**
映射了哪几个插件 `.so`，这是比命令行更硬的一手：

```
apndbplugin.so   mtkbinderpluginext.so   qtibinderpluginext.so   rilbinderplugin.so   rilplugin.so
（binderplugin.so 不在里面）
```

选插件的那段代码在 `/usr/libexec/lxc-android-config/ofonod-wrapper`：

```sh
if [ "$(device-info get OfonoPlugin)" = "binder" ]; then
    disabled_plugins="$disabled_plugins,ril"
else
    disabled_plugins="$disabled_plugins,binder"
fi
```

而 `device-info` 在这台机器上不回答，它**死**：

```
$ device-info get OfonoPlugin
Segmentation fault          rc=139

$ for k in DeviceName PrettyName DeviceType OfonoPlugin SensorfwConfig NoSuchKeyAtAll; do
    device-info get "$k"; echo "rc=$?"; done
DeviceName rc=139   PrettyName rc=139   DeviceType rc=139
OfonoPlugin rc=139  SensorfwConfig rc=139  NoSuchKeyAtAll rc=139
```

每一个键、每一种环境（`env -i`、`HOME=`、`QT_QPA_PLATFORM=offscreen`）都是 139。它**死在哪里**，
`strace -f device-info get DeviceType` 的最后几个系统调用说得清清楚楚：

```
newfstatat(AT_FDCWD, "/dev/__properties__", {st_mode=S_IFDIR|0711, st_size=3340, ...}, 0) = 0
openat(AT_FDCWD, "/dev/__properties__/property_info", O_RDONLY|O_NOFOLLOW|O_CLOEXEC) = 3
mmap(NULL, 26812, PROT_READ, MAP_SHARED, 3, 0) = 0x6fdcb68000
openat(AT_FDCWD, "/dev/__properties__/properties_serial", O_RDONLY|O_NOFOLLOW|O_CLOEXEC) = 3
mmap(NULL, 131072, PROT_READ, MAP_SHARED, 3, 0) = 0x6fdc450000
--- SIGSEGV {si_signo=SIGSEGV, si_code=SEGV_MAPERR, si_addr=0xb00} ---
```

`ltrace -f` 把同一处崩溃定位在 `DeviceInfo::DeviceInfo(PrintMode)`——**构造函数里**，在任何答案被
打印出来之前。而**属性区本身是好的**：宿主的 `/dev/__properties__` 就是容器的那个（目录 inode
`46277`，两边都是 165 个文件；容器的 mountinfo 里它是宿主 `shared:72` 的 `master:72`），
`property_info` 和 `properties_serial` 都 mmap 成功，`default_prop` 里有 13 KB 真属性。二进制也没被动过
（`dpkg -V deviceinfo-tools` 只报 man page 缺失，二进制本身校验通过）。

**所以问题不是"属性区在容器那边"，是"宿主进程在这里根本完成不了一次 Android 属性读取"。**
同一个崩溃、换一个程序、同一个形状：

```
python3 -c "ctypes.CDLL('/lib/aarch64-linux-gnu/libandroid-properties.so.1')
            .property_get(b'ro.product.device', buf, None)"
Segmentation fault
```

而**在容器里问同一个问题有真答案**：

```
nsenter -t 35320 -p -m -- /system/bin/getprop ro.product.device   ->  le_zl1
nsenter -t 35320 -p -m -- sh -c '/system/bin/getprop | wc -l'     ->  695
```

> 这一条同时**修正了 docs 62 里的一句推论**。62 说得对（宿主的 `getprop` 是 stub、bluebinder 必须
> 进容器），但它举的证据是"连真身 `getprop.orig-zl1` 从宿主跑也返回 0 行"，并由此得出"**属性区是容器
> 的**"。现在读得更细：属性区是**共享**的，读不成的是**宿主侧的读取路径**（`libandroid-properties`
> 在属地区初始化里 segfault，可复现）。结论（"要进容器问"）不变，理由是另一个——而理由不同会改变你
> 下一步试什么：前者只能去容器里问，后者说明**任何链接 libandroid-properties 的宿主程序都会崩**，
> 而这正好解释了 ofono 为什么选错插件。

### 2.1 为什么 ril 插件不可能对

```
/etc/ofono/ril_subscription.conf 的全部生效行：
    [Settings]
    [ril_0]
    socket=/dev/socket/rild

$ ls -l /dev/socket/rild
ls: cannot access '/dev/socket/rild': No such file or directory

$ ls /dev/socket/qmux_radio/
qcril_radio_config0  qcril_radio_config1  rild_sync_0  rild_sync_1

$ cat /var/lib/lxc/android/rootfs/vendor/etc/init/rild.legacy.rc
service ril-daemon /vendor/bin/hw/rild
    class main
    user radio
    group radio cache inet misc audio log readproc wakelock
    capabilities BLOCK_SUSPEND NET_ADMIN NET_RAW
```

那就是**整个文件**，而且它是 vendor 镜像里**唯一**提到 rild 的文件：**没有一个 `socket rild` 指令**，
所以 `/dev/socket/rild` 永远不会出现。`rilbinderplugin.so`（Sailfish 的 binder 传输版 ril 插件）
要的是 **Android 8 以前**那个 `rild` binder 服务，HIDL 时代的 rild 也不注册它。

---

## 3. 门二：命名空间（同一堵墙的第五次）

同一个二进制、同一份配置、同样的参数，**只换命名空间**：

```
宿主命名空间：
  ofonod[1950681]: Initializing RIL binder transport plugin.
  [gbinder] WARNING: registerForNotifications(android.hardware.radio.config@1.0::IRadioConfig) failed

容器 PID 命名空间（zl1-ns-exec）：
  ofonod[11762]: Initializing RIL binder transport plugin.
  ofonod[11762]: Missing path for slot slot1
  ofonod[11762]: Missing path for slot slot2
```

容器里它已经能从 hwservicemanager **枚举出两个 slot**；宿主里它连注册都做不到。

顺带读掉一个容易搞错的东西：**设备节点不是差别**。两边打开的是同一个：

```
宿主：      /dev/binder 15430  /dev/hwbinder 15431  /dev/vndbinder 15432
容器：      /dev/binder 15430  /dev/hwbinder 15431  /dev/vndbinder 15432
```

（同一 inode、同一 `st_dev`。）所以"进容器"这一步不能靠"把节点 bind 过来"省掉——这也是
`zl1-ns-exec` 存在的理由，而它已经在设备上（bluebinder、sensorfwd、biometryd、
lomiri-location-service 都用它）。

---

## 4. 门三：`/etc/ofono/binder.conf`

插件和命名空间都对了之后，它仍然拒绝：

```
ofonod[...]: Missing path for slot slot1
ofonod[...]: Missing path for slot slot2
```

`binderplugin.so` 的字符串里有 `binder.conf`、`[slotN]`、`path`、`slot`、`radioInterface`、
`extPlugin`、`ExpectSlots`、`IgnoreSlots`、`Device`、`InterfaceType`。上游
（`mer-hybris/ofono-binder-plugin`，版权 `Jolla Ltd. 2021-2022`，和装着的包一致）的 README 说：

> For reliable startup, /etc/ofono/binder.conf has to list all expected slots, for example:
> `[Settings] ExpectSlots = slot1,slot2`

> The exceptions are "path" and "slot" values which must be unique and therefore must appear in the
> section(s) for the respective slot(s).

> `radioInterface` … Default 1.2 (android.hardware.radio@1.2::IRadio)

最后这句是**这台机器特有的第二个坑**：设备只注册到 **1.1**（§1 的 lshal 列表），默认值 1.2
在这里没有对应的服务。而这个文件在 port 上**不存在**，`/etc/ofono` 又在只读镜像上：它**不在**
`/etc/fstab` 的白名单里（`grep ofono /etc/fstab` 只匹配到 `/var/lib/ofono`，那是 ofono 的**存储**目录，
不是它的**配置**目录）。

于是文件是这样供应进去的——不挂载任何全局的东西，只给 ofonod 一个**私有的 mount namespace**：

```
BindPaths=/userdata/zl1-ofono/etc:/etc/ofono
```

`zl1-ns-exec` 只进 PID namespace、**从不进 mount namespace**，所以这个私有挂载被它 exec 出来的子进程
继承。`/etc/ofono` 里的 `main.conf`（`[ModemManager] AutoSelectDataSim` 是这里唯一不是默认值的设置）
是从镜像**拷**过去的，不是重写的。

---

## 5. 证据：装上之后，真的两个 modem

**装之前**先在私有总线上做了一次实验（`/etc/ofono` 用 tmpfs 覆盖，做完 umount，镜像的三个文件原样回来）：

```
[gbinder-radio] Connected to android.hardware.radio@1.1::IRadio/slot1
[gbinder-radio] Connected to android.hardware.radio@1.1::IRadio/slot2

busctl --address=… call org.ofono / org.ofono.Manager GetModems
a(oa{sv}) 2
  "/ril_0" … "Powered" b true "Revision" s "MPSS.TH.2.0.c1.9.1-00044" "Serial" s "861579037654648"
            "Interfaces" as 4 org.ofono.VoiceCallManager org.ofono.SimManager
                              org.nemomobile.ofono.CellInfo org.nemomobile.ofono.SimInfo
            "Features" as 1 "sim"   "Type" s "hardware"
  "/ril_1" … "Serial" s "861579037654655"
```

**装上之后**，在**真系统总线**上，`systemctl restart ofono` 后 12 秒：

```
unit:      active (1973204)
GetModems: a(oa{sv}) 2 "/ril_0" … "Online" b true "Powered" b true …
```

而这段开机的 journal 把前后两句话放在一起，比任何转述都清楚：

```
ofonod-wrapper[37946]: [grilio-socket] ERROR: Can't connect to RILD: No such file or directory
systemd[1]: Stopping ofono.service…
ofonod[37946]: Exit
systemd[1]: Starting ofono.service…
zl1-ns-exec[1973208]: ofonod[12816]: Initializing RIL binder transport plugin.
systemd[1]: Started ofono.service - oFono Mobile telephony stack.
```

设备整体：`systemctl is-system-running` = `running`，`--failed` = **0 个单元**，`boot_id` 前后未变。

---

## 6. 这一页**没有**成立的东西

* **没有 SIM——而且这一条现在是 modem 自己说的，不是推论。**（同日第二次读数，同一次开机。）
  第一次只有 ofono 的概括 `"Present" b false`，**分不出"空卡槽"和"有卡没认出来"**。这个问题不属于
  ofono 的配置，它属于 radio HAL，所以把 ofonod 用 **debug 打开**在私有总线上又跑了一次（同样的
  tmpfs 覆盖、跑完 umount），插件自己的 RPC 轨迹就在日志里，答案是 modem 的真回复：

  ```
  slot1 < [00000003] 2 getIccCardStatus
  slot1 > [00000003] 1 getIccCardStatusResponse
  src/binder_sim_card.c:binder_sim_card_status_new()
      card_state=0, universal_pin_state=0, gsm_umts_index=-1, ims_index=-1, num_apps=0
  src/binder_plugin.c:binder_plugin_slot_sim_state_changed() No SIM in slot 0
  （slot2 完全相同，`No SIM in slot 1`）
  ```

  一次运行里 4 次 `getIccCardStatus`，**每一次都有回复**。`card_state=0` 是 HIDL 的
  `CardState::ABSENT`，`num_apps=0` 且两个 app 索引都是 -1：**两个卡槽上都没有 ICC 应用**。

  于是 SIM 这一半在软件上已经走到底了，它说的是：**modem 报没有卡**。
  **这条读数证明了整条路径是通的**——`IRadio::getIccCardStatus` 进、`CardStatus` 回、ofono 状态出，
  这正是"modem 被驱动起来了"的含意。它**不能**定的只有一件事：卡槽里到底有没有一张卡——
  卡槽插着而卡没插，和卡插着但 modem 认不出来，**报的都是这个**，而唯一的证人就是 modem，
  它的答案是"absent"。要分开这两者需要人看一眼卡槽；这台机器上没有任何软件读数能分开。
  唯一能改变 ofono 行为的旋钮是 `extPlugin`，**它不是这个的原因**（它管的是 IMS/VoLTE 的细节，
  不是卡检测）。

* **顺带看到的一个真实缺陷（不是新的）**：容器的 `vsimservice` 在崩溃循环——
  `init.svc.vendor.vsimservice: [restarting]`，logcat 里每 5 秒一行
  `F linker: CANNOT LINK EXECUTABLE "/vendor/bin/vsimd": library "libQSEEComAPI.so" not found`
  ——就是那条已经离线定过的 ELF class 不匹配（32 位的 `/vendor/bin/vsimd`，只有 64 位的
  `libQSEEComAPI.so`）。它是**虚拟 SIM** 的守护进程，不在物理卡要走的路上；代价是每 5 秒一次失败的
  exec 加一行 logcat。

* **跨重启的持久性没有量过。** 它写的两个东西都在会持久的分区上（`/etc/systemd/system` 是
  `/userdata/system-data/etc/systemd/system` 的 bind，`/userdata` 是 `/dev/sda10`），而且这就是
  十几个 `zl1-*` 单元早就在用的机制——但**装完之后没有冷启动过**。
* `Power request failed`：ofono 起来 30 秒后出现过一次（binder 插件）。`Online` 还是变成了 `true`，
  `Powered` 没掉过。记下来，不解释。
* **跨重启的持久性没有量过。** 它写的两个东西都在会持久的分区上（`/etc/systemd/system` 是
  `/userdata/system-data/etc/systemd/system` 的 bind，`/userdata` 是 `/dev/sda10`），而且这就是
  十几个 `zl1-*` 单元早就在用的机制——但**装完之后没有冷启动过**。
* 这次没有重读别的子系统：相机、GPS、指纹都还是上一轮（docs 123、166、167）的读数。

---

## 7. 两个自己写出来的读数缺陷，记在这里

写 `--status` 的时候自己踩了两个，都是这个仓库反复记过的形状：

1. **`MainPID` 不是 ofonod。** 挂上 wrapper 之后 systemd 的主 PID 是 **nsenter**（`-p` 必须 fork，
   setns 只影响之后创建的子进程），ofonod 是它的孩子。所以从 `MainPID` 的 `/proc/<pid>/maps` 和
   `ns/pid` 读出来的，是**关于 nsenter 的答案**：在"两个 modem 已经枚举出来"的那次运行里，它报
   "binder 插件没有加载"。修法：从单元 cgroup 里找 cmdline 含 `ofonod` 的那个进程
   （这台机器是 **cgroup v1**，路径是 `/sys/fs/cgroup/systemd<ControlGroup>/cgroup.procs`；
   `/proc/<pid>/task/<tid>/children` 在这个内核上**不存在**，`CONFIG_PROC_CHILDREN` 没开）。
2. **`grep binderplugin.so` 会匹配到 `rilbinderplugin.so`。** 于是"binder 插件在不在"这个问题，
   在一个只映射了 ril-over-binder 那个插件的启动上会答"在"——正是这一行存在的意义所给出的**错误**
   答案。修法：模式里带斜杠 `/binderplugin\.so`。

另外，第一次 `--install` 在推 `binder.conf` 时打印的是 `refusing: could not push binder.conf`，
真正的原因（`SCP` 数组根本没定义，被 `set -u` 抓住）被我自己的 `2>/dev/null` 丢掉了。
"不说明原因的拒绝"就是这个仓库一直在写仪器去防的那个东西——这一行现在不吞 stderr 了。

---

## 8. 阶段位置

硬件清单上"一次真机读数都没有"的那个子系统，现在**有两个在跑的 modem**。它带来的不是"电话能打了"，
而是三件事：

| | 之前 | 现在 |
|---|---|---|
| `GetModems` | `a(oa{sv}) 0`（每一次开机） | **`a(oa{sv}) 2`** |
| ofono 用的插件 | ril（socket 不存在） | **binder**（`binderplugin.so` 已加载） |
| ofonod 的命名空间 | 宿主 | **容器**（与容器 `ns/pid` 相同） |

还没成立的是**跨重启的持久性**（§6）：写的东西都在持久分区上、机制和十几个 `zl1-*` 单元一样，
但装完之后没有冷启动过。**SIM 那一格已经填上了**——填的是 modem 自己的答案（没有卡），
以及一句更重要的话：**整条路径是通的**，这是"modem 被驱动起来了"的含意。
下一个阶段回到硬件清单上还没驱动起来的那几项：**相机 app 上没上屏**、**GPS 一次定位都没有过**、
**指纹的驱动编进了镜像但没刷**，以及**散热那三条里第 ② 条（cpufreq governor）的效果从没单独量过**。
