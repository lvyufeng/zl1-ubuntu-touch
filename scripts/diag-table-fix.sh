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
