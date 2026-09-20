#!/bin/sh
# 在设备上判断：三表修复为什么时灵时不灵
L=/data/zl1-netwatch.log
echo "=== 1. netwatch 跑起来了吗 ==="
grep -c 'netwatch start' "$L" 2>/dev/null || echo "0（日志不存在或没启动过）"
grep -oE '^[0-9.]+s netwatch start[^|]{0,60}' "$L" 2>/dev/null | head -3
echo
echo "=== 2. policy 修复的日志说了什么 ==="
grep -oE '^[0-9.]+s policy routing fix[^|]{0,70}' "$L" 2>/dev/null | head -20
echo
echo "=== 3. added 的次数 = 表被清后补回的次数 ==="
grep -c 'policy routing fix: added' "$L" 2>/dev/null
echo
echo "=== 4. route_get 成功/失败的比例 ==="
echo "in place: $(grep -c 'policy routing fix in place' "$L" 2>/dev/null)"
echo "NOT working: $(grep -c 'policy routing fix NOT working' "$L" 2>/dev/null)"
echo
echo "=== 5. 设备侧看到的链路可达率 ==="
echo "OK:   $(grep -c 'host-ping: OK' "$L" 2>/dev/null)"
echo "FAIL: $(grep -c 'host-ping: FAIL' "$L" 2>/dev/null)"

echo
echo "=== 6. netd 在重启吗（doc 36 的假设）==="
echo "fwmarkd socket 创建次数（dmesg）:"
dmesg 2>/dev/null | grep -c 'Created socket .*/dev/socket/fwmarkd' || echo "0"
echo "--- 每次创建的 uptime ---"
dmesg 2>/dev/null | grep 'Created socket .*/dev/socket/fwmarkd' | sed 's/^\[ *\([0-9.]*\)\].*/\1/' | tail -10
echo
echo "=== 7. netd / zygote 的 PID 现在是多少 ==="
for p in netd zygote zygote64; do
  pid=$(pgrep -f "^/system/bin/$p" 2>/dev/null | head -1)
  [ -n "$pid" ] && echo "$p pid=$pid starttime=$(cat /proc/$pid/stat 2>/dev/null | awk '{print $22}')" || echo "$p: 不在"
done
echo
echo "=== 8. Android 框架到哪一步了 ==="
cpid=$(pgrep -f 'lxc-start -n android' | head -1)
if [ -n "$cpid" ]; then
  echo "container pid=$cpid"
  ls -l "/proc/$cpid/root/dev/.coldboot_done" 2>/dev/null || echo "coldboot_done: 无"
  echo "容器内进程数: $(ls /proc/$cpid/root/proc 2>/dev/null | grep -c '^[0-9]' || echo '?')"
fi

echo
echo "=== 9. 备选方案：给 rndis0 的出包打 mark，走 netd 已有的规则 ==="
echo "当前 mangle OUTPUT 链:"
iptables -t mangle -L OUTPUT -n -v 2>/dev/null | head -8
echo
echo "如果上面没有 -o rndis0 的 MARK 规则，可以试:"
echo "  iptables -t mangle -A OUTPUT -o rndis0 -j MARK --set-mark 0x10063"
echo "  ip route show table 97   # 确认表 97 有路由"
echo "  ip route get 192.168.2.100   # 应该能解析"
