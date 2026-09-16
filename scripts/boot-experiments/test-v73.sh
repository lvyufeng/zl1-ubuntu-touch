#!/bin/bash
echo "=== V73 测试脚本 ==="
echo ""

echo "1. 配置 RNDIS 驱动和网络"
sudo modprobe rndis_host
sleep 2

if ! ip link show usb0 >/dev/null 2>&1; then
  echo "✗ usb0 未出现"
  echo "检查设备状态..."
  lsusb | grep 18d1
  exit 1
fi

sudo ip link set usb0 up
sudo ip addr flush dev usb0
sudo ip addr add 192.168.2.100/24 dev usb0
sudo ip addr add 10.15.19.100/24 dev usb0
echo "✓ 网络配置完成"
echo ""

echo "2. 测试连接"
if ping -c2 -W2 10.15.19.82 >/dev/null 2>&1; then
  echo "✓ Ping 成功！"
else
  echo "✗ Ping 失败"
  exit 1
fi
echo ""

echo "3. 测试 HTTP GET"
if curl -s -m5 http://10.15.19.82:8080/ | head -10; then
  echo "✓ HTTP GET 工作！"
else
  echo "✗ HTTP GET 失败"
  exit 1
fi
echo ""

echo "4. 测试 HTTP POST /exec (新功能！)"
echo "测试命令: uname -a"
curl -X POST http://10.15.19.82:8080/exec -d 'cmd=uname -a'
echo ""
echo ""

echo "测试命令: ls /dev/fb*"
curl -X POST http://10.15.19.82:8080/exec -d 'cmd=ls /dev/fb*'
echo ""
echo ""

echo "测试命令: ip addr show"
curl -X POST http://10.15.19.82:8080/exec -d 'cmd=ip addr show'
echo ""

echo "=== V73 测试完成！==="
