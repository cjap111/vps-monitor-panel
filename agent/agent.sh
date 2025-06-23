#!/bin/bash

# --- 配置 (这些值会在一键安装时被自动替换) ---
BACKEND_URL="https://monitor.yourdomain.com/api/report" # 后端API上报地址
SERVER_ID="default-id" # 服务器唯一ID
SERVER_NAME="Default Server Name" # 服务器名称
SERVER_LOCATION="Default Location" # 服务器位置
NET_INTERFACE="eth0" # 监控的网络接口，通常是eth0或ensXXX

# --- 数据采集 (增加了容错处理) ---

# 获取操作系统信息
OS=$(hostnamectl | grep "Operating System" | cut -d: -f2 | xargs)

# 获取CPU使用率 (百分比)
CPU_USAGE=$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1}' || echo 0)

# 获取内存信息 (单位：兆字节 MB)
MEM_INFO=$(free -m | grep Mem)
MEM_TOTAL=$(echo $MEM_INFO | awk '{print $2}' || echo 0)
MEM_USED=$(echo $MEM_INFO | awk '{print $3}' || echo 0)

# 获取磁盘信息 (单位：兆字节 MB)
# 使用 -BM 参数获取M单位的磁盘大小，更稳定
DISK_INFO=$(df -BM / | tail -n 1)
# 从df输出中提取总空间，并去除'M'单位
DISK_TOTAL=$(echo $DISK_INFO | awk '{print $2}' | sed 's/M//' || echo 0)
# 从df输出中提取已用空间，并去除'M'单位
DISK_USED=$(echo $DISK_INFO | awk '{print $3}' | sed 's/M//' || echo 0)

# 获取瞬时网络速度 (单位：字节/秒 B/s)
# sar -n DEV 1 1: 报告网络设备的统计信息，每1秒采集1次
# grep "Average:": 筛选平均值行
# grep $NET_INTERFACE: 筛选特定网络接口的统计信息
NET_STATS=$(sar -n DEV 1 1 | grep "Average:" | grep $NET_INTERFACE || echo "Average: $NET_INTERFACE 0 0 0 0 0 0 0 0")
# awk '{print $5}': 提取接收KB/s
NET_DOWN_KBPS=$(echo $NET_STATS | awk '{print $5}' || echo 0)
# awk '{print $6}': 提取发送KB/s
NET_UP_KBPS=$(echo $NET_STATS | awk '{print $6}' || echo 0)
# 将KB/s转换为B/s (1KB = 1024B)
NET_DOWN_BPS=$(echo "$NET_DOWN_KBPS * 1024" | bc || echo 0)
NET_UP_BPS=$(echo "$NET_UP_KBPS * 1024" | bc || echo 0)

# 获取原始累计流量 (用于后端计算流量增量，单位：字节 Bytes)
# /sys/class/net/$NET_INTERFACE/statistics/rx_bytes: 累计接收字节数
# /sys/class/net/$NET_INTERFACE/statistics/tx_bytes: 累计发送字节数
RAW_TOTAL_NET_DOWN=$(cat /sys/class/net/$NET_INTERFACE/statistics/rx_bytes || echo 0)
RAW_TOTAL_NET_UP=$(cat /sys/class/net/$NET_INTERFACE/statistics/tx_bytes || echo 0)

# --- 组装JSON数据 ---
JSON_PAYLOAD=$(cat <<EOF
{
  "id": "$SERVER_ID",
  "name": "$SERVER_NAME",
  "location": "$SERVER_LOCATION",
  "os": "$OS",
  "cpu": $CPU_USAGE,
  "mem": { "total": $MEM_TOTAL, "used": $MEM_USED },
  "disk": { "total": $DISK_TOTAL, "used": $DISK_USED },
  "net": { "up": $NET_UP_BPS, "down": $NET_DOWN_BPS },
  "rawTotalNet": { "up": $RAW_TOTAL_NET_UP, "down": $RAW_TOTAL_NET_DOWN }
}
EOF
)

# --- 上报数据 ---
# 使用curl发送POST请求到后端API
curl -s -X POST -H "Content-Type: application/json" -d "$JSON_PAYLOAD" $BACKEND_URL
