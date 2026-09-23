# 105 — GPS 那道门的第一个客户端已经在设备上：预装的天气应用

**日期**: 2026-09-23
**状态**: 纯离线的一轮（设备在 EDL，`05c6:9008` / port 3-3，与 `86`–`104` 同）。[`93`](93-gps-the-door-is-a-client-request-and-the-two-levers-are-dead.md) 把 GPS 的问题收敛成一个问题——**"第一次请求从哪里来"**——并在镜像里证明了 `u_hardware_gps_new` / `u_hardware_gps_start` 只在一次客户端请求里被调到。这一轮回答**谁来请求**，答案不需要写任何新代码，也不需要绕过任何权限：**预装的天气应用 `weather.ubports_weather_6.2.0` 就是一个被 AppArmor 政策允许的位置客户端。**

**接续**: [`93`](93-gps-the-door-is-a-client-request-and-the-two-levers-are-dead.md)（门 = 客户端请求，两把 `getprop` 钥匙插不进去）、[`82`](82-the-gps-line-read-the-source-and-the-rootfs.md)（UT 侧 / Android HAL 侧那一刀）、[`80`](80-the-ut-camera-app-starts-and-our-preload-was-breaking-egl.md) + [`84`](84-the-camera-app-on-screen-is-one-command-now.md)（把**任意** UT 应用在会话里起起来的 launcher，`device/zl1-camapp-launch.py`）、[`77`](77-*.md)（截图 ≠ 活性）。

---

## 1. 一句话结论

| 问题 | 答案 |
|---|---|
| 谁能按这扇门？ | **天气应用**（click 名 `weather.ubports`，应用 id `weather.ubports_weather_6.2.0`），预装，`/usr/share/click/preinstalled/weather.ubports/6.2.0` |
| 证据一：它真的是个位置客户端？ | 它的 QML（编译进 `lomiri-weather-app`）里有 `import QtPositioning 5.12 //for coordinate query` 和 **`PositionSource { }`**，而它的 `active` 绑在一个设置上：`active: settings.detectCurrentLocation` |
| 证据二：政策允许它？ | 应用自带的 `lomiri-weather-app.apparmor` 的 `policy_groups` 里**第一个就是 `location`**；烘焙好的 profile `/var/lib/apparmor/profiles/click_weather.ubports_weather_6.2.0` 里逐字带着 system bus 上 `com.lomiri.location.Service` 与 `com.lomiri.location.Service.Session` 的 send/receive 规则（profile 第 507–537 行，注释就是 `# Description: Can access Location`） |
| 三道闸在这台设备上有人回答吗？ | **有。** AppArmor 是开着的（UT boot 的 cmdline 里 `apparmor=1 security=apparmor`，defconfig 里有 `CONFIG_SECURITY_APPARMOR`），而 trust-store agent 是**已启用**的用户单元——两个互斥变体按一个 `ConditionPathExists` 二选一（§4） |
| 那为什么从来没有发生过？ | 因为**没有人按**。`lomiri-location-serviced-cli` 只能读写那两个开关、不能请求位置（`82`）；而会去请求的预装客户端每个都各有一个条件（天气是 `detectCurrentLocation`，出厂 **false**，见 §3） |
| 那要怎么按？ | 用**相机那一轮已经验证过的 launcher** 把天气起起来（它对应用是通用的），在应用里把 *detect current location* 打开 → `PositionSource` 变 active → 位置服务建会话 → 三道闸 → `u_hardware_gps_new` / `u_hardware_gps_start` **第一次被调用** |
| 需要绕过权限吗？ | **不需要。** 这是系统支持的那条路：应用的政策组里就有 `location`，trust store 的 agent 会（按设计）问用户。`zl1-location-request.sh --enable-testing` 仍然是不通时的后备，但它是**真实的权限绕过**，应当是最后手段 |
| 动设备了吗？ | 没有。整轮只读挂载，设备仍在 EDL |

---

## 2. 客户端：逐条证据

### 2.1 它是 QtPositioning 客户端，不是"用了定位图标"

`strings` 直接给出 QML 源码行（QML 编译进二进制）：

```
import QtLocation 5.12 //for geocoding
import QtPositioning 5.12 //for coordinate query
    PositionSource {
        active: settings.detectCurrentLocation
```

「coordinate query」正是 `PositionSource`；而 `active:` 绑在设置上，说明**这是一次真实的 `StartPositionUpdates`**（QtPositioning 的 lomiri 插件就是走 `com.lomiri.location.Service` 建会话、再在会话上调 `StartPositionUpdates`），而不是只读缓存。

### 2.2 政策已经把这条路铺好了

click 包的 `.apparmor`：

```json
{
    "policy_groups": [
        "location",
        "networking",
        "connectivity",
        ...
```

而 `policygroups/ubuntu/1.0/location` 这个组写的就是 `com.lomiri.location.Service` / `.Session` 在 **system bus** 上的 DBus 规则（`peer=(name="com.lomiri.location.Service",label=unconfined)`）。也就是说：**镜像自己承认这个应用有权用位置**，而 door 的守护进程**恰好就是** `label=unconfined`（它没有自己的 AppArmor profile）。

### 2.3 它是"预装"的，不需要装任何东西——而且它不是唯一一个，只是最直接的那个

`ls /usr/share/click/preinstalled/` 里有 `weather.ubports`（6.2.0）。同样带 `PositionSource` 的预装应用还有两个，它们的 QML 是**可读的源文件**（天气的是编译进二进制的）：

| 应用 | 位置客户端在哪 | 备注 |
|---|---|---|
| `weather.ubports` 6.2.0 | 编译进 `lomiri-weather-app` 的 QML | `active: settings.detectCurrentLocation`；定位就是"当前城市" |
| `clock.ubports` 4.1.1 | `share/lomiri-clock-app/clock/ClockPage.qml`（源文件） | 大概是自动时区 |
| `camera.ubports` 4.1.1 | `qml/Viewfinder/ViewFinderOverlay.qml`、`BarcodeReaderOverlay.qml` | 给照片写地理位置 |

三个都可用，**选天气是因为它的开关就是"用定位"本身**：时钟的定位是时区的副作用，相机的要先拍照。

顺带一条使"QtPositioning 就是这条链"成立的证据：`qt5/plugins/position/` 下有 **`libqtposition_lomiri.so`**——即 QtPositioning 在这台设备上有一个 lomiri 后端（`device/zl1-location-request.sh --request` 起的就是 `PositionSource { name: "lomiri" }`）。所以上面这些 `PositionSource` 不是装饰，它们就是会走到 `com.lomiri.location.Service` 的那条路。

---

## 3. 那个开关在哪（以及为什么它出厂是关的）

`lomiri-weather-app-migrate.py`（应用 desktop 文件里的 Exec 就是它，`os.execvp` 到真二进制）自己算出了设置文件的位置：

```python
db_file = xdg_data_home / organization / "Databases" / f"{hashlib.md5(application.encode()).hexdigest()}.sqlite"
```

`organization = application = "weather.ubports"`，所以设备上（`XDG_DATA_HOME=/home/phablet/.local/share`）：

```
/home/phablet/.local/share/weather.ubports/Databases/0404df7c9de73501aad24e64d39120e1.sqlite
/home/phablet/.local/share/weather.ubports/Databases/0404df7c9de73501aad24e64d39120e1.ini
```

（`md5("weather.ubports") = 0404df7c9de73501aad24e64d39120e1`；`.ini` 是 Qt QML LocalStorage 给 sqlite 配的旁车文件。）

应用的 `databases/*.conf` 模板把默认值写得很清楚：

```
[weatherSettings]
detectCurrentLocation=false
```

**所以这是一个"读得到、也可以预先写"的开关**：正常做法是在应用里点开它（屏幕和触摸都已经由用户确认可用），需要脚本化时也可以直接改那个 `.ini`——但**别**在应用运行时改（QML LocalStorage 会把它写回去）。

---

## 4. 顺带确认：锁那边也有人在

`93` §3.3 说 trust-store 那一侧"是接好线的"，这一轮把**怎么接的**读全了。`/usr/lib/systemd/user/` 里有两个互斥单元，都在 `graphical-session.target.wants` 下**已启用**：

| 单元 | 条件 | local agent |
|---|---|---|
| `lomiri-location-service-trust-stored.service` | `ConditionPathExists=/run/user/%U/mir_socket_trusted` | `MirAgent --trusted-mir-socket=${XDG_RUNTIME_DIR}/mir_socket_trusted` |
| `lomiri-location-service-trust-stored-wayland.service` | `ConditionPathExists=!/run/user/%U/mir_socket_trusted` | `WaylandAgent` |

两个条件互为反命题，所以**恰好一个会跑**（同一个 `trust-stored-skeleton`，都带 `--for-service LomiriLocationService --with-text-domain lomiri-location-service --store-bus session`）。同一族还有 `pulseaudio-trust-stored*.service` 和 `cameraservice-trust-stored.service`——`69` 记过相机那个在反复重启，说明这条链在设备上是活的、只是吵。

两者的差别只在**谁弹窗**：有 `mir_socket_trusted` 就走 Mir 提示（`MirAgent`），否则走 Wayland 提示（`WaylandAgent`）。**这正是设备上要确认的两件事**：agent 有没有真的起来、以及用的是哪一个。

---

## 5. 设备上要跑什么（等设备回到 RNDIS）

```sh
IP=10.15.19.82
scp scripts/device/zl1-camapp-launch.py root@$IP:/tmp/                 # 相机那一轮用的同一个 launcher

APP=/usr/share/click/preinstalled/weather.ubports/6.2.0
ssh root@$IP "A=\$(lxc-info -n android -pH 2>/dev/null | head -1); S=\$(pgrep -x lomiri | head -1)
  setsid nohup nsenter -t \$A -p -- timeout 300 env ZL1_AS_UID=32011 \
    ZL1_PRELOAD_EXTRA='/userdata/zl1-hybris/lib/libcfi-shadow-init.so /userdata/zl1-hybris/lib/crash-dump.so' \
    python3 /tmp/zl1-camapp-launch.py $APP/lomiri-weather-app weather.ubports_weather_6.2.0 $APP \$S \
    > /tmp/zl1-weather.out 2> /tmp/zl1-weather.err < /dev/null &"
```

然后在应用里打开 **detect current location**（设置页那一项）。接着看门：

```sh
ssh root@$IP 'journalctl -b -u lomiri-location-service --no-pager -o cat | tail -40'
ssh root@$IP 'systemctl --user status "lomiri-location-service-trust-stored*.service" | head -40'
ssh root@$IP 'sh /tmp/zl1-location-request.sh --status'      # 只读；它会说三道闸哪一道关着
ssh root@$IP 'cat /tmp/zl1-weather.err'                      # 应用自己说了什么
```

判读要点：

* 看到 `Client lacks permissions to access the service with the given criteria`（客户端的报错是 `Error.CreatingSession` / `Error creating session`）→ **闸 3 关了**，而且是 `catch(...)` 吞掉的那种拒绝，"拒绝"和"agent 坏了"在这里长得一模一样——所以第 2 条 `systemctl --user status` 必须一起看；
* 看到建会话成功、并且此后 `u_hardware_gps_new` / `u_hardware_gps_start` 被调用的痕迹（`82` 的设备侧那条线：`locClientOpen failed` 是不是**没有**出现）→ **这道门在移植史上第一次被打开**，Android HAL 那一半第一次被要求做点什么。

---

## 6. 这一篇**不**证明什么

* **不证明 HAL/QMI 那一半能出位置。** `82`/`93` 的结论是"那一半从来没被要求做过任何事"，所以它好还是坏**至今没有被检验过**。这一篇只把"请求"这件事变得可做。
* **不证明 trust store 会答应。** 上游源码里 `catch(...)` 把异常静默变成 `rejected`，客户端看不到区别；也可能弹出提示等人点。
* **天气应用还没在这台设备上起过。** launcher 是对相机写的；它对应用是通用的（读会话环境、丢掉 server 侧 `MIR_SERVER_*`/`QT_QPA_PLATFORM`、设 `MIR_SOCKET` + `QT_QPA_PLATFORM=ubuntumirclient`、最后 `setuid`），但天气多带一个 `libQt5WebEngine.so.5`（预报页面用）——WebEngine 在这台设备上从未验证过，它可能拖住或让应用起不来。**起不来不是 GPS 的结论，是应用的结论**，两者要分开读。
* **别跳过迁移步骤。** desktop 的 Exec 是 `lomiri-weather-app-migrate.py lomiri-weather-app`；直接起二进制会跳过它，第一次运行时（配置/数据库模板 + `Name=com.ubuntu.weather` → `weather.ubports` 的改名）就没有发生。起了没反应时，先单独跑一遍迁移脚本。
* **`detectCurrentLocation` 的确切读取位置是从迁移脚本的算法 + Qt LocalStorage 的约定推出来的**，不是从设备上读到的（设备在 EDL）。应用在应用里点开关这件事不依赖它，只有"预写配置文件"那条路依赖。

---

## 7. 设备状态

整轮没有动设备：没有写任何分区或 boot，没有跑 QDL/QFIL，没有重启。设备仍在 **Qualcomm EDL**（`05c6:9008`，port 3-3，无序列号）。识别目标一律按序列号 **`33e80afe`**；总线上另一台小米 **`4a2fe00b`** 必须忽略。恢复仍然只能靠**物理长按电源 10–20 秒**。
