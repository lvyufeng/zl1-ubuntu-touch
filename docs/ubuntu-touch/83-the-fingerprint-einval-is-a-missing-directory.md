# 83 — 指纹的 `SYS_EINVAL` 不是 HAL 坏了：那个目录在真 Android 上是 **system_server** 建的，而这个 port 没有 system_server

**日期**: 2026-09-23
**状态**: 纯离线的一轮（设备在 EDL，见 [`80`](80-the-ut-camera-app-starts-and-our-preload-was-breaking-egl.md) §7）。`64` §9 挂着"指纹：`setActiveGroup failed: SYS_EINVAL` 只是被 `RestartSec=5` 节奏化了，没有修好"。把**这条链上四份源码按顺序读一遍**，答案是结构性的、而且窄到一行：**HAL 在 `access(storePath, W_OK)` 上失败（ENOENT）**，因为 `/data/system/users/0/fpdata` 这个目录**在真 Android 上由 `system_server` 创建**，而这个 port 里没有 `system_server` —— 没人建它。HAL 那一支**连日志都不打**，这正是设备日志里只有调用方那句、HAL 一言不发的原因。

**接续**: [`64`](64-the-last-unit-was-not-failing-it-was-obeying.md) §9（这条待办的原始记录）、[`55`](55-the-bridge-libraries-built-and-hwbinder-does-not-cross-pid-namespaces-either.md)/[`56`](56-the-two-services-move-into-the-containers-pid-namespace.md)（桥接库与容器 namespace 搬迁）、[`82`](82-the-gps-line-read-the-source-and-the-rootfs.md)（同一轮里 GPS 那两处读反）

---

## 1. 四份源码，顺序就是答案

**(a) HAL 侧 —— 两个 `SYS_EINVAL`，只有第一个会说话**
`device/leeco/zl1/biometrics/BiometricsFingerprint.cpp:215-228`：

```cpp
Return<RequestStatus> BiometricsFingerprint::setActiveGroup(uint32_t gid,
        const hidl_string& storePath) {
    if (storePath.size() >= PATH_MAX || storePath.size() <= 0) {
        ALOGE("Bad path length: %zd", storePath.size());
        return RequestStatus::SYS_EINVAL;
    }
    if (access(storePath.c_str(), W_OK)) {
        return RequestStatus::SYS_EINVAL;      // <-- 一个字的日志都没有
    }
    int ret = mDevice->set_active_group(mDevice, gid, storePath.c_str());
    ...
}
```

第二个分支**静默**。所以设备日志里"只有调用方的 `setActiveGroup failed: SYS_EINVAL`、HAL 一句不说"这件事本身就是判据：它排除了"路径长度"这一支，指向 `access()`。

**(b) 调用方 —— 路径是它写死的，而且有两支**
`halium/biometryd/src/biometry/devices/android.cpp:590-598`（`android` 设备构造，也就是 biometryd 起来时）：

```cpp
std::string api_level = store.get("ro.product.first_api_level");
if (api_level.empty()) api_level = store.get("ro.build.version.sdk");
if (atoi(api_level.c_str()) <= 27)
    ret = u_hardware_biometry_setActiveGroup(hybris_fp_instance, 0, (char*)"/data/system/users/0/fpdata/");
else
    ret = u_hardware_biometry_setActiveGroup(hybris_fp_instance, 0, (char*)"/data/vendor_de/0/fpdata/");
if (ret != SYS_OK) printf("setActiveGroup failed: %s\n", ...);
```

这条路是 `biometryd → libbiometry_fp_api.so → UHardwareBiometry_::setActiveGroup → IBiometricsFingerprint::2.1`，也就是设备日志里那句 `Connected to IBiometricsFingerprint::2.1 service` 的同一条链。**路径不由用户/框架给，由 biometryd 按 API level 选。**

**(c) 真 Android 里这个目录是谁建的 —— `system_server`**
`frameworks/base/services/core/java/com/android/server/fingerprint/FingerprintService.java:1585-1622`：

```java
private void updateActiveGroup(int userId, String clientPackage) {
    IBiometricsFingerprint daemon = getFingerprintDaemon();
    if (daemon != null) {
        ...
        if (userId != mCurrentUserId) {                     // <-- 只在活动用户变化时才做
            int firstSdkInt = Build.VERSION.FIRST_SDK_INT;
            File baseDir = (firstSdkInt <= Build.VERSION_CODES.O_MR1)
                           ? Environment.getUserSystemDirectory(userId)      // /data/system/users/<id>
                           : Environment.getDataVendorDeDirectory(userId);   // /data/vendor_de/<id>
            File fpDir = new File(baseDir, FP_DATA_DIR);      // 常量 = "fpdata"（同文件 :109）
            if (!fpDir.exists()) {
                if (!fpDir.mkdir()) { Slog.v(TAG, "Cannot make directory: " + ...); return; }
                if (!SELinux.restorecon(fpDir)) { Slog.w(TAG, "Restorecons failed..."); return; }
            }
            daemon.setActiveGroup(userId, fpDir.getAbsolutePath());
            mCurrentUserId = userId;
        }
```

**目录是框架建的**（`fpDir.mkdir()` + `restorecon`），而且**建不出来就直接 `return`，连 `setActiveGroup` 都不会调**。HAL 里那个 `access(W_OK)` 之所以成立，是因为在这一行之前目录已经存在、且属于 `system_server`。

**(d) 这个 port 里谁建它 —— 没有人**
* 容器里**没有 `system_server`**（Halium 的设计；`65` 整篇就是在给相机补它本该提供的服务）；
* `halium/biometryd` 里除了 (b) 那两行路径常量，**没有任何 `mkdir`**；
* `device/leeco/zl1/biometrics/*.rc` 里也**没有** `mkdir`（`grep mkdir` 的结果是空），只有 `on boot` 下一次 `chown/chmod` 那些 sysfs 和 `/dev` 节点。

所以 (b) 那两行常量里的第一个目录**大概率从来不存在**，`access()` 返回 ENOENT，HAL 静默回 `SYS_EINVAL`。

**顺带钉死一件事：失败发生在 HAL 打开之后。** 这一个二进制同时做两份工作（`device/leeco/zl1/biometrics/service.cpp`）：注册 legacy 的 `fingerprintd` binder 服务（`FingerprintDaemonProxy::descriptor`），再用 `bio->registerAsService()` 注册 HIDL 的 `IBiometricsFingerprint`。而 `service.cpp` 里的 `ALOGE("Start fingerprintd")` / `ALOGE("Start biometrics")` 是 **ALOGE**，所以它们必然落在 logcat 里；设备日志里那句 `Connected to IBiometricsFingerprint::2.1 service`（`64` 记的）说明 HIDL 服务**注册成功**了，也就是 `openHal()` 走通了 —— 于是 `openHal()` 里的 `hw_get_module("fingerprint")`、`/dev/goodix_fp`、`gx_fpd` 那一层**这一刻是好的**，故障在它之后，也就是 `setActiveGroup`。这把可能的范围又缩掉一段。

## 2. 于是问题被压成一句可检查的话

> **`/data/system/users/0/fpdata` 在 HAL 进程自己看到的那套 mount namespace 里存在吗？存在的话，HAL 的 uid 写得进去吗？**

> **2026-09-24 更正（[`126`](126-the-path-was-decided-by-what-the-stub-omits.md)）：这个问句里的路径写错了，而本篇的"两个候选路径都要看"正是让它没变成错误结论的那一句。**
> 设备上 biometryd 传的是 **`/data/vendor_de/0/fpdata`**（v63 那个 stub 答 `ro.build.version.sdk`=28、
> 不认 `ro.product.first_api_level`，于是走 `> 27`），不是本篇写的那一个。本篇的诊断（"`SYS_EINVAL` 是
> 一个缺失的目录"）**不受影响**——因为 §2 第 3 条要求两个候选都看，而设备上两个都 MISSING；
> 受影响的只是"要建哪一个"。见 [`126`](126-the-path-was-decided-by-what-the-stub-omits.md)。

三个细节决定了这句必须这么问：

1. **`access()` 用的是 HAL 自己的 real uid，和它自己的 mount namespace。** 容器里 `/data` 不是主机的 `/data`（主机上是 `/android/data` = `/dev/sda10[/android-data]`，rw ext4）。所以唯一诚实的查法是 **`/proc/<hal-pid>/root/data/...`** —— 那个路径是经由目标进程的 namespace 解析的，不需要猜 `nsenter` 该带哪些 flag；
2. **uid 要从 `/proc/<hal-pid>/status` 读**，不能信 rc 里的 `user system`（那是 Android init 的写法，容器里实际跑成什么 uid 要实测；如果 HAL 是 root，`access(W_OK)` 对任何存在的目录都成立，那就只剩"不存在"这一种可能）；
3. **两个候选路径都要看**：(b) 的分支由 API level 决定，而 **`atoi("")` 是 0，所以属性读不到时会落到 `<= 27` 那一支** —— 也就是说"属性没读出来"这个故障模式和 Android 8 的正常结果**是同一条路径**，不会把诊断带偏。

## 3. 修法（一行，而且可逆）

`scripts/device/zl1-fingerprint-probe.sh --create-store-dir` 做**真 Android 的 `FingerprintService` 做的同一件事**：在容器的 mount namespace 里 `mkdir -p` **那条规则选中的路径**（写这篇时以为是 `/data/system/users/0/fpdata`，设备上是 `/data/vendor_de/0/fpdata`，见 `126`；探针从来不写死，它按 biometryd 的规则现算），按 HAL 实测的 uid 决定要不要 `chown`（HAL 是 root 就不用），并打印 undo（`nsenter -t <container> -m -- rmdir ...`）。

把它归类清楚，因为这是这一轮唯一会写东西的地方：

* 写的是 **Android 自己的 `/data`**（主机上的 `/android/data`，`/dev/sda10[/android-data]`，一个平常就在写的 rw ext4）—— **不是** `modemst1/2`、`fsg`、`fsc`、`persist`、`modem`、`dsp`、`bluetooth` 里的任何一个，**不是**分区镜像，**不是**刷写；
* 它建的**就是真 Android 自己会建的那个目录**，路径、层级、位置都一致（这是 (c) 里那份 Java 代码逐字给出的）；
* 可逆：目录为空时 `rmdir` 就撤销；
* 默认**不**执行：探针默认只读，`--create-store-dir` 是个显式开关。

**这一轮没有执行它**（设备在 EDL），也没有任何东西被写。

## 4. 设备回来后怎么判（三行，都在探针输出里）

| 观察到 | 结论 | 下一步 |
|---|---|---|
| `MISSING /data/system/users/0/fpdata` + logcat 里 `Bad path length` = 0 | §1 的诊断成立，就是没人建目录（**2026-09-24：设备上两条路径都是 MISSING，而 biometryd 传的是 `vendor_de` 那条，见 `126`**） | `--create-store-dir`，然后重启报错的那个服务，看 logcat 的 `setActiveGroup failed` 是否归零 |
| `EXISTS` 但 uid 不匹配且无写位 | 目录在，权限错 | `chown` 到 HAL 的 uid（探针的同一个开关会做） |
| `EXISTS` 且可写，仍然 `SYS_EINVAL` | **§1 的诊断被推翻** | 那就只剩 `mDevice->set_active_group()` 里那个 Goodix HAL 自己返回的错误了 —— 那时才轮到 `/dev/goodix_fp`、`gx_fpd`、QSEECom 那一层 |

探针还会一起打出来：HAL 是否在跑（按 cmdline 匹配 `biometrics.fingerprint*service`，不猜 comm 截断）、它的 uid/gid 与 `ns/pid`/`ns/mnt`、两个 store 路径**经它自己 namespace** 解析的存在性与权限、`ro.product.first_api_level` / `ro.build.version.sdk`（**在容器里读**，见 [[zl1-android-properties-are-only-visible-in-the-container]]）、logcat 里八个关键字符串的计数（含 `Bad path length` 和 `Can't open fingerprint HW Module` 这两个"本该出现却没有"的）、fingerprint HIDL 注册、`/dev/goodix_fp` 的存在与权限、SELinux 的 `enforce` 值。

## 5. 复现

```sh
scp scripts/device/zl1-fingerprint-probe.sh root@10.15.19.82:/tmp/
ssh root@10.15.19.82 'sh /tmp/zl1-fingerprint-probe.sh'                  # 只读
ssh root@10.15.19.82 'sh /tmp/zl1-fingerprint-probe.sh --create-store-dir'   # 那一行写，显式
```

| 文件 | 作用 |
|---|---|
| `scripts/device/zl1-fingerprint-probe.sh` | 新增。默认**只读**收集 §4 表里的全部观察；`--create-store-dir` 是唯一会写的开关，做 (c) 那份 Java 做的事并打印 undo |
| `docs/ubuntu-touch/83-*.md` | 本篇 |

## 6. 这一轮**不**证明什么

* **没有在设备上量任何东西**（设备在 EDL）。§1 是**读四份源码**的结论：`BiometricsFingerprint.cpp`（设备固件的 HAL）、`biometryd/android.cpp`（UT 侧的调用方）、`FingerprintService.java`（真 Android 里建目录的人）、`device/leeco/zl1/biometrics/*.rc`（确认这个 port 里没有别的东西建它）。
* **不证明那个目录在设备上不存在**：它是**最可能**的情形（§1d：没有人建），但那正是 §4 第一行要去查的；如果它其实存在（这台手机当年跑过真正的 Android，`/data` 可能是从那时候留下来的），诊断就落到第二/三行。
* **不证明 `--create-store-dir` 能让指纹工作**：它最多把 `SYS_EINVAL` 这一关过去；再往后还有 Goodix 的 `set_active_group`、`/dev/goodix_fp`、QSEECom 那条路 —— `55`/`56` 记录过它们各自的坎。
* **不证明 SELinux 不会挡住新建的目录**：真 Android 建完要 `restorecon`（(c) 里那一行），探针只把 `enforce` 读出来；这个 port 的容器里 SELinux 是否 enforcing 没查过。
