# 63 — 最后一个失败单元：安装器两次说"装好了"，两次都是路径写错

**日期**: 2026-09-21
**状态**: **`systemctl --failed` 现在是空的。** 从这天早上七个 `failed (Result: signal)` 一路收口到最后一个 `update-machine-info-from-deviceinfo` —— 它拖得最久，原因**不在设备，在这个安装器自己**。它两次报"写了 N 个 drop-in"，而目标 unit 一个都没有：两条路径 bug 叠在一起，每一条都能单独造成"看起来装了、实际没装"。修掉之后 unit `Result=success / ExecMainStatus=0`，冷启动 `c86ce828-d3d0-4c33-b18f-151a8fe09160` 复核 0 个失败单元。
**接续**: [`48`](48-the-tls-fault-was-killing-seven-system-services.md)（TLS 槽位 1 这条线）、[`62`](62-bluetooth-two-things-that-read-from-the-wrong-place.md)（上一个收口的 unit）

---

## 1. 现象：安装器说"写了 17 个"，目标 unit 还是 `failed`

`update-machine-info-from-deviceinfo` 是唯一一个从头到尾没被修好的 unit。它的病已经查清了（`48` 那条线）：`Result=signal` / `ExecMainStatus=11`，`strace` 里 `SIGSEGV {si_code=SEGV_MAPERR, si_addr=0xb00}`，`ltrace` 里死在 `libdeviceinfo.so.0->property_get(...)` 之后 —— 它**不链接 `libgbinder`**，但经由 `libdeviceinfo.so.0 → libandroid-properties.so.1 → libhybris-common.so.1` **传递地**走到了 bionic 的 `property_get`，撞上同一个空 TLS 槽位。手工验证过：`LD_PRELOAD=/usr/lib/aarch64-linux-gnu/libtls-padding.so` 一加，退出码就是 0。

所以修法是现成的：给它一个 drop-in。而 `install-system-tls-preload.sh --install` 两次都报成功：

```
  found by scan: aethercast hfd-service mechanicd repowerd snapd.autoimport
                 snapd.seeded snapd update-machine-info-from-deviceinfo urfkill
wrote 17 drop-in(s)
```

而设备的回答是：

```
$ ls /etc/systemd/system/update-machine-info-from-deviceinfo.service.d/zl1-tls.conf
ls: cannot access '...': No such file or directory
$ systemctl show update-machine-info-from-deviceinfo.service -p Result -p ExecMainStatus --value
signal
11
```

**"写了 17 个"和"这个 unit 没有 drop-in"同时成立。** 而且不是"少写了一个"—— 是**每个扫描出来的 unit 都没写**，只有手写清单里的那几个（它们本来就在早期的运行里装好了）在。

## 2. 第一个 bug：后缀被去掉，又被加回来，成了两个

`--install` 分两半：远端扫描打印 `名字 可执行文件路径`，本地收下、去重、拼成一串名字，再通过环境变量送进第二段远端脚本去写。名字在这条路上被处理了两次：

```sh
# 本地：把扫描输出里的 unit 名取出来
scan_units=$(... | awk '{print $1}' | sed 's/\.service$//')     # foo.service -> foo
...
"${SSH[@]}" "UNITS='$(printf '%s %s' "$scan_units" "$EXTRA_UNITS" | tr -s ' ')' bash -s" <<'REMOTE'
# 远端：一个名字直接当 unit 名用，并自己补后缀
for u in $UNITS; do
  systemctl list-unit-files --type=service "$u.service" >/dev/null 2>&1 || continue
```

本地为了"统一成裸名"**去掉了** `.service`，远端又**假设自己是裸名**、理所当然地补上 `.service`。两头看起来都自洽，合起来是把扫描出来的名字全部变成 `foo.service.service`，`systemctl list-unit-files --type=service foo.service.service` 当然找不到，`|| continue` 静静跳过。

**没有任何报错，只有一个偏大的计数。** 手写清单 `EXTRA_UNITS` 里本来就没有后缀，所以它们不受影响 —— 这就是为什么"一部分装上了、一部分没有"而计数看起来还正常。

这个 bug 的前身是反向的：更早的版本远端不补后缀，扫描输出（带后缀）直接被当路径用，结果一样。**两头都改一次后缀，就必然错一次。**

修法不是在某一头删掉那行，而是**在每个名字第一次被当成 unit 名的地方归一化一次**，之后不再动它：

```sh
add() {
  u=$1
  case "$u" in
  *.service) ;;
  *) u="$u.service" ;;
  esac
  ...
}
```

判据是"这个名字是裸名还是全名"在字符串上无法分辨，所以**不能靠约定**，只能靠一次显式的归一化。

## 3. 第二个 bug：`<name>.d` 不是 `<name>.service.d`，systemd 根本不读

第一条修好之后计数从 8 变成 17，unit **还是 failed**。查设备才发现文件其实写下来了，只是写在了错的地方：

```
/etc/systemd/system/aethercast.service.d      <- 早期版本写的（正确）
/etc/systemd/system/aethercast.d              <- 后来的版本写的（systemd 不读）
/etc/systemd/system/update-machine-info-from-deviceinfo.d -> contains: zl1-tls.conf
```

因为路径是 `mkdir -p "/etc/systemd/system/$u.d"` —— `$u` 是裸名，目录就成了 `foo.d`。**systemd 的 drop-in 目录必须以 unit 的完整名字命名，后缀不能少**：service 是 `foo.service.d`，socket 是 `foo.socket.d`，以此类推。`foo.d` 只有在一个叫 `foo`（没有后缀）的 unit 文件旁边才有意义，而这台机器上没有任何这种 unit。

**所以 `foo.d/zl1-tls.conf` 是一个从不生效的文件。** 三条证据：

- 它存在，而 unit 继续 `status=11/SEGV` —— 修的是 `property_get` 的 TLS 槽位，如果环境变量真的进去了，它不会崩。
- `systemctl cat update-machine-info-from-deviceinfo.service` 的续写文件那一节里**没有**这个 drop-in。
- 把文件换到 `foo.service.d/` 之后，`systemctl cat` 立刻列出了它：

  ```
  # /usr/lib/systemd/system/update-machine-info-from-deviceinfo.service
  ...
  # /etc/systemd/system/update-machine-info-from-deviceinfo.service.d/zl1-tls.conf
  [Service]
  Environment=LD_PRELOAD=/usr/lib/aarch64-linux-gnu/libtls-padding.so
  ```

这也是为什么 `--status` 一开始没喊：它按 `*.service.d/zl1-tls.conf` 枚举，"服务有 shim"的计数 10 是对的，**而那 10 个里没有目标 unit** —— 计数正确，结论错误。

## 4. 判据：怎么一眼看出 drop-in 到底生效没有

一个 drop-in 文件存在，只说明有人写了它。判断"systemd 会不会读"要问 systemd 自己：

```
systemctl cat <unit>          # 输出的续写文件段里有没有这个 drop-in 文件
systemctl show <unit> -p Environment --value
```

`systemctl cat` 是这里的正确工具，因为它做的就是 systemd 的解析：它把 unit 的主文件、所有 `<unit>.d/` 目录、以及符号链接全部展开。文件在，`cat` 里没有 —— 那就是路径错了，不用再猜。

## 5. 修法

1. **名字归一化一次**，`add()` 里做，guard 和路径都用归一化后的全名（`foo.d` 与 `foo.service.service` 两处病灶一起消掉）。
2. **清理旧的 `foo.d`**：`--install` 和 `--remove` 都会扫 `/etc/systemd/system/*.d`，把不是 `*.service.d`/`*.socket.d`/`*.target.d`/`*.timer.d`/`*.mount.d` 且里面躺着 `zl1-tls.conf` 的目录删掉。留着它们比删掉更危险 —— 一个后来的人看到文件在那儿，会得出"这个 unit 的 shim 装好了"的结论。
3. **`--status` 增加一个 STRAY 段**，把这类目录单独列出来报警，而不是混在计数里。

清理那一步在设备上的输出（12 个，全部是这一版写歪的）：

```
  removed stray /etc/systemd/system/aethercast.d (ignored by systemd)
  removed stray /etc/systemd/system/biometryd.d (ignored by systemd)
  ...
  removed stray /etc/systemd/system/update-machine-info-from-deviceinfo.d (ignored by systemd)
wrote 17 drop-in(s)
```

`17` 这个数字现在是对的：9 个扫描出来的 + 8 个手写的，其中 5 个重名，就是 12 个文件。

## 6. 验证：这个 unit 跑完，`systemctl --failed` 空了

```
$ systemctl cat update-machine-info-from-deviceinfo.service   # 见 §3
$ journalctl -b -u update-machine-info-from-deviceinfo.service | tail -3
  ... Main process exited, code=killed, status=11/SEGV        <- 修之前
  ... [info] No device yaml config found!
  ... Deactivated successfully.
  ... Finished update-machine-info-from-deviceinfo.service
$ systemctl show update-machine-info-from-deviceinfo.service -p Result -p ExecMainStatus --value
success
0
```

日志里那几行 `tlsfix2 main pid=… slot1_was=0x0000000000000000` 就是 shim 自己的诊断输出：它确实被加载了，也确实看到槽位 1 是空的（这正是那个 SIGSEGV 的原因），然后把它填上了。unit 是 `Type=oneshot`，所以它 `inactive (dead)` 配 `Result=success` 是**正常终态**，不是没跑。

`--status` 现在长这样（末尾的 `still failing:` 是空的）：

```
services with the shim (from the /etc/systemd/system writable-path):
  aethercast.service               active
  biometryd.service                active
  hfd-service.service              active
  lomiri-location-service.service  active
  mechanicd.service                active
  repowerd.service                 active
  sensorfwd.service                active
  snapd.autoimport.service         inactive
  snapd.seeded.service             active
  snapd.service                    active
  update-machine-info-from-deviceinfo.service inactive
  urfkill.service                  active

shim in place: /usr/lib/aarch64-linux-gnu/libtls-padding.so
still failing:
```

### 冷启动 `c86ce828-d3d0-4c33-b18f-151a8fe09160`（t≈122 秒）

```
failed units:                （空）
update-machine-info:         Result=success ExecMainStatus=0
容器 PID 命名空间 pid=36102
  lomiri-location-service    active  success NRestarts=2
  biometryd                  active  success NRestarts=2
  sensorfwd                  active  success NRestarts=2
  bluebinder                 active  success NRestarts=2
lightdm / urfkill / mechanicd / repowerd / hfd-service   active
hci0 在；wlp1s0、p2p0 在
```

`NRestarts=2` 仍然是重试在正常工作（容器和 HAL 还没到），不是故障。

## 7. 还差的：pretty hostname 没变，因为设备没有 yaml

> **更正（[`64`](64-the-last-unit-was-not-failing-it-was-obeying.md)）**：这一节的观察对象错了 —— 主机名的来源不是 deviceinfo 的 yaml，而是这个 unit "只在当前 pretty hostname 为空时才写"的策略加上镜像里那个 `PRETTY_HOSTNAME="Generic device"`。而且设备**本来就通过兜底路径把自己认对了**（`Name: le_zl1` / `PrettyName: LeEco Pro3` / `DeviceType: phone` / `GridUnit: 21`），`/etc/deviceinfo/devices/` 也根本是只读的。下面这段保留原样，因为它记录的是当时的推断过程。

`update-machine-info-from-deviceinfo` 现在**成功退出**了，但 `hostnamectl` 还是：

```
   Static hostname: ubuntu-phablet
   Pretty hostname: Generic device
```

原因在它自己的日志里，而且是一个**和崩溃无关**的问题：

```
[info] No device yaml config found!
```

`libdeviceinfo` 的模型是按名字找配置：`/etc/deviceinfo/devices/<name>.yaml`。这台机器上有 `halium.yaml`、`pinephone*.yaml`、`pinetab*.yaml`，**没有 zl1 的**。没有配置文件就没有数据可写，于是它照着 `default.yaml` 的 `default:` 段填了 `PrettyName: Generic device`、`DeviceType: desktop`、`GridUnit: 8`。

`pinephone.yaml` 说明了这个文件长什么样 —— 顶层的键是设备名，`Names:` 是 DTB model 字符串的白名单：

```yaml
pinephone:
  Names:
    - Pine64 PinePhone (1.2)
  PrettyName: Pine64 PinePhone
  DeviceType: phone
  GridUnit: 14
  PrimaryOrientation: Portrait
  SensorfwConfig: /etc/deviceinfo/sensorfw/pinephone.conf
```

这台机器的 `/proc/device-tree/model` 是 `Letv Technologies, Inc. MSM 8996pro + PMI8996 LE_ZL1-DVT1`。写一个 zl1 的 yaml 是要做的下一步，它不只改 hostname：`DeviceType` 现在被报成 **desktop**（而不是 phone）、`SensorfwConfig` 也没有 —— 而 `sensorfwd` 的 `ExecStart` 里带着 `--device-info`，也就是说传感器那一路现在吃的也是默认值。**这一篇只把 unit 修到成功；设备自我描述那件事单独算一段。**

## 8. 这一段改了哪些东西

**设备上**（全是运行时；**没有**写任何分区、**没有**动引导镜像、**没有**动容器里的东西）：

- `/etc/systemd/system/` 下 **12 个 `foo.d/zl1-tls.conf` 被删掉**（systemd 从来没读过它们），换成了两个正确的 `aethercast.service.d/zl1-tls.conf` 和 `update-machine-info-from-deviceinfo.service.d/zl1-tls.conf`。
- 其余 10 个 `.service.d` drop-in 内容未变。
- 设备做了一次冷启动（`c86ce828-…`），起来之后 GUI / Wi-Fi / 蓝牙 / 四个容器服务 / 0 个失败单元。

**仓库里**：`scripts/hybris-shims/install-system-tls-preload.sh` —— `add()` 归一化名字、`--install`/`--remove` 清理 `foo.d`、`--status` 增加 STRAY 段、头部注释补上这两个坑。
