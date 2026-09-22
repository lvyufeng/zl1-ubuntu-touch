# 73 — 用户的手指把三件事同时定案了：**返回键在内核这一层是好的**（shell 只在三个界面上用它）、**会话是活的**（点一下就把 gallery 拉起来了）、以及 qbt1000 那颗键控器从来不出声

**日期**: 2026-09-22
**状态**: **用户拿着手机操作了 51 秒，`zl1-watch-input.py`（不抓取）把这 51 秒的每一个 evdev 事件都记了下来 —— 3146 行、64 次触摸手势、154 个按键事件。三条结论都是这份记录直接给出的，不是推断：**

1. **返回键的硬件和内核是好的。** `synaptics_dsx`（触摸屏）上真实地出现了 `KEY BACK(158)` 的按下/抬起（t=505.974/506.051、506.659/506.792），还有 `KEY HOMEPAGE(172)` 9 次、`KEY APPSELECT` 1 次；电源键 `KEY POWER(116)` 在 `qpnp_pon` 上。**所以"返回键不能用"不是硬件、不是驱动、不是触摸屏的问题，`[`70`](70-the-landscape-was-the-shell-laying-itself-out.md)`/`[`71`](71-the-sensors-stream-the-restart-kills-the-hal.md)` 之前怀疑的对象全部可以排除。**
2. **而 shell 那边：`Key_Back` 在整个 `/usr/share/lomiri/` 里只出现在三个文件**（`PinLockscreen.qml`、`Launcher.qml`、`Stage/Spread/Spread.qml`），**应用窗口里没有处理器**。实测对上了：用户在 gallery 在前台时按了两次 BACK，shell 的日志在那 11 秒里**一条都没有**（既不关应用、也不切前台、也没有任何 session 事件）。**这就是"返回键不能用"的准确形状：它在设计上只属于锁屏/启动器/应用铺开那三个界面。**
3. **`qbt1000_key_input` 一个事件都没出** —— 它声明了 225 个键（那个 `0xfe` 重复模式），但整个 51 秒里 0 个事件。**过去一直在看错的设备**：这颗手机的两颗电容键是触摸屏报的，不是键控器报的。（电容键同时声明在 `synaptics_dsx` 的能力位图里 —— 见 `[`71`](71-the-sensors-stream-the-restart-kills-the-hal.md)` 之后新增的 `zl1-input-devices.py`。）
4. **顺带推翻 [`68`](68-the-camera-stage-was-one-cookie-in-the-stub.md) §7 的前提**："手机停在锁屏 greeter，解不开就没人能看见任何窗口" —— **不是这样**。用户在这一窗口里点开了两个应用：`lomiri-gallery-app`（11663.97）和 `lomiri-filemanager-app`（11678.25），both 拿到了 Mir 的 `SessionAuthorizer::connection_is_allowed`、开始渲染（`Last frame took 41 ms` / `Mir buffer is gl:TextureSource`），shell 甚至给它们加了启动器图标（`Received a surface count changed event from an app that's not in the Launcher model, creating icon...`，11682.04）。**会话是活的、可交互的，能启动应用。**

**接续**: [`72`](72-the-heat-was-the-governor-and-a-debug-keeper.md)（同一轮的散热）、[`71`](71-the-sensors-stream-the-restart-kills-the-hal.md)、[`68`](68-the-camera-stage-was-one-cookie-in-the-stub.md)（§7 的前提在这里被推翻）

---

## 1. 记录是怎么取的，以及为什么可信

```
nohup setsid python3 /userdata/zl1-watch-input.py --seconds 1800 --log /userdata/zl1-input-watch.log &
```

工具的三个性质决定了这份记录能用：**不 `EVIOCGRAB`**（抓取会把设备从合成器手里夺走，被测的输入就到不了该响应它的东西那里 —— 而合成器启动时就打开了 event0-5、event7，之后不热插拔，见 [`68`](68-the-camera-stage-was-one-cookie-in-the-stub.md) §6）；**不过滤**；**一个 `select()` 循环盯 8 个节点**，所以设备之间的先后是真的。日志的时间戳是**相对进程启动的秒数**，进程启动于 uptime **11162.47**，所有换算都从这里来。

| 设备 | 事件数 | 说明 |
|---|---|---|
| `synaptics_dsx`（触摸屏） | **3131 + 键事件** | 触摸、以及两颗电容键 |
| `qpnp_pon` | 4 | 电源键按下/抬起 |
| `qbt1000_key_input` | **0** | 声明 225 键，一个不出 |
| 其余 5 个 | 0 | 耳机/HDMI/触摸板等，没人碰 |

## 2. 用户按了什么（全部按键事件，逐行）

```
t=497.166  uptime=11659.6  qpnp_pon       KEY POWER      1     <- 短按电源键（点亮屏幕）
t=497.325  uptime=11659.8  qpnp_pon       KEY POWER      0
t=504.295  uptime=11666.8  synaptics_dsx  KEY HOMEPAGE   1
t=505.974  uptime=11668.4  synaptics_dsx  KEY BACK       1     <- 返回键
t=506.051  uptime=11668.5  synaptics_dsx  KEY BACK       0
t=506.659  uptime=11669.1  synaptics_dsx  KEY BACK       1     <- 又按一次
t=506.792  uptime=11669.2  synaptics_dsx  KEY BACK       0
t=507.274  uptime=11669.7  synaptics_dsx  KEY APPSELECT  1
t=521.512 … 527.361        synaptics_dsx  KEY HOMEPAGE   1/0  ×8   <- 连按
```

加上 64 次触摸手势（`BTN_TOUCH` + `MT_POSX/MT_POSY` + `key:325`=BTN_TOOL_FINGER），位置从状态栏（y=40）到屏幕最下沿（y=1862）都有。

**读法**：`KEY BACK` 和 `KEY HOMEPAGE` 都带完整的 down/up，没有粘键、没有丢失 —— 这是一颗**工作正常**的电容键。`APPSELECT` 也出得来。

## 3. 断点在 shell，而且断得很具体

```
$ grep -rl "Key_Back" /usr/share/lomiri/
/usr/share/lomiri/Components/PinLockscreen.qml
/usr/share/lomiri/Launcher/Launcher.qml
/usr/share/lomiri/Stage/Spread/Spread.qml
```

**只有这三处。** 也就是说 Lomiri 对返回键的定义是：PIN 锁屏、启动器、应用铺开（spread）。**一个普通应用窗口在前台时，返回键没有任何处理器** —— 而实测完全对上：

```
BACK 按下发生在 uptime 11668.4 / 11669.1
shell(pid 901569) 的日志在 11668–11670 之间：一条都没有
   （前后最近的 log 是 11667.128 的一帧渲染、和 11678.227 的下一个应用的授权）
```

对比同一次会话里 HOMEPAGE 的效果：用户连按之后，11690.73 立刻有一帧渲染（`Last frame took 42 ms`），说明**它确实被 shell 接住了**（切到启动器/spread，会重绘）。所以两个键的差别不是"能不能送达"，而是**"有没有人接"**。

> 这一条同时解释了用户最早那句 **"返回键似乎不能用"**：在应用里按它，按设计就是没反应；而在启动器/PIN/铺开界面里按它是有反应的。要"返回"，Lomiri 的手势是**从左边缘往右划**（日志里 `EdgeBarrierSettings: min=2gu(36px)…` 就是这套边缘手势的配置）。

## 4. 会话是活的：用户点开了两个应用（推翻 `68` §7 的前提）

```
[11663.796] lomiri: qtmir.sessions: Wakelock acquired "11"
[11663.968] lomiri: SessionAuthorizer::connection_is_allowed  pid=911701
[11663.984] lomiri: TaskController::onSessionStarting - sessionName=lomiri-gallery-app
[11664.152] lomiri: [PERFORMANCE]: Last frame took 41 ms to render.
[11665.366] lomiri: Mir buffer is gl:TextureSource (old)
[11678.247] lomiri: TaskController::onSessionStarting - sessionName=lomiri-filemanager-app
[11682.044] lomiri: Received a surface count changed event from an app that's not in the Launcher model, creating icon...
```

`TaskController::onSessionStarting` = 应用真的作为 Mir 会话起来了；`gl:TextureSource` + `Last frame took 41 ms` = 它在渲染；"creating icon" = 它在启动器里有了位置。**用户是通过手指点开的**（对应窗口里的手势：11663.3 在 `(103, 967)` 的一次点击，正好在 gallery 的会话起来前 0.7 秒）。

**所以 `68` §7 那句"没人能看见任何窗口"是错的**（至少现在是）：这台设备会启动应用、会把它们画出来。它当时可能是在说"相机预览那个窗口"看不见，而不是"screens 全都没人看" —— 但写下来的字面意思是前者，这里更正。

## 5. 顺带撞上的两件事

**(a) `orientationsensor` 在动的时候是会出值的。** 用户拿起手机的这段里，shell 收到了真实的新读数并改了几次方向：`[11690.866] new orientation=Qt::PortraitOrientation`、`[11696.250] new orientation=Qt::PortraitOrientation`，之后又一次 `unknown`。这和 [`71`](71-the-sensors-stream-the-restart-kills-the-hal.md) §4 一致：**它不是在"永远不出值"，而是在"平放不动时不出值"** —— 输入（加速度计/陀螺仪）一直在流，姿态判据在那段静置里没被重算。**横屏那条的正式修法要从这里入手**（用户已选择"按正确姿态修，不牺牲自动旋转"），下一步是 `sensorfwd -c=<path>` 指向我们自己的配置 + `-l debug` 看 chain/interpreter 为什么静置时不重算。

**(b) lightdm 的本地登录被 `nopasswdlogin` 挡着，这是一颗定时炸弹而不是当前故障。**

```
/etc/pam.d/lightdm:  auth sufficient pam_succeed_if.so user ingroup nopasswdlogin
journalctl:          pam_succeed_if(lightdm:auth): requirement "user ingroup nopasswdlogin" not met by user "phablet"
                     gkr-pam: no password is available for user
```

`phablet` **不在** `nopasswdlogin` 里（`/etc/group` 第 51 行是 `nopasswdlogin:x:112:`），而 `phablet` 也**没有密码** —— 于是"sufficient 那一跳失败 → 落到 `common-auth` → 没人能输密码"。上游 UT 的镜像里 phablet 本来就在这个组里，所以这是这个 port 的镜像缺了一行。

修法（**已做，运行时，完全可逆**）：`/etc/group` 在只读镜像里，但 `/var/lib/extrausers` 是 `/dev/sda10` 上的持久可写挂载、而且是 `nsswitch.conf` 里的一个 group 源；不过 `getgrnam` 只返回 `files` 那一份（`getent group nopasswdlogin` 仍然看不到成员），所以真正生效的做法是**把一份改了一行的副本 bind-mount 到 `/etc/group` 上**：

```sh
cp -a /etc/group /userdata/etc-group.orig
sed 's/^nopasswdlogin:x:112:$/nopasswdlogin:x:112:phablet/' /userdata/etc-group.orig > /userdata/etc-group.overlay
mount --bind /userdata/etc-group.overlay /etc/group
```

验过：`getent group nopasswdlogin → nopasswdlogin:x:112:phablet`、`id phablet → …112(nopasswdlogin)`、87 个组照常可见、`sudo -n -l -U phablet` 正常、systemd 正常。**只读镜像本身没有任何一个字节被写**，`umount /etc/group` 就是撤销。同时也在 extrausers 里加了一行（两个源现在都看得见这条成员关系）。

> **诚实标注：它的效果还没有被证明。** 这个 boot 里一共只有两次 `pam_succeed_if` 失败（[8987.97] 和 [10788.88]，相隔正好 1801 秒 = 30 分钟，像是某个周期性的会话尝试），**都在这次修改之前**；修改之后还没有任何一次 login 尝试发生过，所以"现在能不能空密码登录"没有任何直接证据。它可能是 30 分钟后才轮到下一次尝试。也**不能**说"是它解开了锁屏" —— 用户能点开应用这件事发生在它之前就已经成立（§4 的会话一直是活的）。

## 6. 下一步

1. **等下一次 lightdm 登录尝试**（每 ~30 分钟一次，或用户手动锁屏后解锁一次），看 `pam_succeed_if` 那行是消失还是照旧。这是唯一能把 §5 那个"还没证明"变成结论的测量。**如果它照旧失败**，下一步就是 `mount -o remount,rw /` 直接改 `/etc/group`（或者给 phablet 设一个密码），而不是继续绕。
2. **横屏的正确姿态**（用户的选择）：`sensorfwd -c=<我们自己的配置>` + debug 日志，看 `orientationsensor` 的 chain/`orientationinterpreter` 为什么静置不重算、以及 `6` 是怎么算出来的（§5a）。
3. **返回键要不要"在应用里也能用"**：这需要改 `/usr/share/lomiri/`（只读），但可以用和 §5 一样的 bind-mount 手法覆盖单个 QML 文件。**这是产品决定**（上游 Lomiri 就是只在三处响应它），要先问用户要不要偏离上游。
4. **相机**：§4 已经把 `68` §7 的前提推翻了，所以"看见预览"这件事现在可以重新量 —— 会话是活的、能出图。

## 7. 文件与复现

| 文件 | 作用 |
|---|---|
| `docs/ubuntu-touch/evidence/zl1-input-watch-2026-09-22.log` | 用户那 51 秒的原始记录：3146 行，8 个设备头、3131 个触摸屏事件、全部按键事件 |
| `scripts/device/zl1-watch-input.py` | 记录器（不抓取、不过滤、一个 select 循环） |
| `scripts/device/zl1-input-devices.py` | 能力位图（"这个设备能报什么"），与上面那个"实际报了什么"配对 |

```sh
# 记录（不抓取，所以不会把输入从合成器手里夺走）
nohup setsid python3 /userdata/zl1-watch-input.py --seconds 1800 --log /userdata/zl1-input-watch.log &
# 只看非触摸的按键事件
grep " KEY " /userdata/zl1-input-watch.log | grep -vE "BTN_TOUCH|key:325"
# 设备能报什么（键位图）
python3 /userdata/zl1-input-devices.py
# shell 有没有对某个键做什么（按它的 pid 过滤 journal 索引，别全量 grep）
journalctl -b _PID=$(pgrep -x lomiri) -o short-monotonic | grep -viE "Infographics|TypeError"
```

**设备安全**：只往 `/userdata/` 写（记录、probe、备份）。只读地看 `/proc`、`/sys`、journal、`/usr/share/lomiri`。改变设备状态的动作：`mount --bind` 一个 `/etc/group` 副本（`umount` 撤销，只读镜像零写入）、往持久可写的 `/var/lib/extrausers/group` 追加一行（原文件已备份到 `/userdata/`）、重启过一次 greeter、以及用 repowerd 自己的接口把显示按住。**没有** remount 根文件系统、没有改 `/etc/sensorfw`、没有碰分区或 boot 镜像、没有动容器内的文件。容器 RUNNING，`systemctl --failed` 空，SSH 正常。
