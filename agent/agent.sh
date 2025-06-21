#!/bin/bash

# --- 配置 (这些值会在一键安装时被自动替换) ---
BACKEND_URL="https://monitor.yourdomain.com/api/report"
SERVER_ID="default-id"
SERVER_NAME="Default Server Name"
SERVER_LOCATION="Default Location"
NET_INTERFACE="eth0"

# --- 数据采集 ---
OS=$(hostnamectl | grep "Operating System" | cut -d: -f2 | xargs)
CPU_USAGE=$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1}')
MEM_INFO=$(free -m | grep Mem)
MEM_TOTAL=$(echo $MEM_INFO | awk '{print $2}')
MEM_USED=$(echo $MEM_INFO | awk '{print $3}')
DISK_INFO=$(df -h / | tail -n 1)
DISK_TOTAL=$(echo $DISK_INFO | awk '{print $2}' | sed 's/G//')
DISK_USED=$(echo $DISK_INFO | awk '{print $3}' | sed 's/G//')

# 瞬时速度
NET_STATS=$(sar -n DEV 1 1 | grep "Average:" | grep $NET_INTERFACE || echo "Average: $NET_INTERFACE 0 0 0 0 0 0 0 0")
NET_DOWN_KBPS=$(echo $NET_STATS | awk '{print $5}')
NET_UP_KBPS=$(echo $NET_STATS | awk '{print $6}')   
NET_DOWN_BPS=$(echo "$NET_DOWN_KBPS * 1024" | bc)
NET_UP_BPS=$(echo "$NET_UP_KBPS * 1024" | bc)

# 原始累计流量 (用于计算增量)
RAW_TOTAL_NET_DOWN=$(cat /sys/class/net/$NET_INTERFACE/statistics/rx_bytes)
RAW_TOTAL_NET_UP=$(cat /sys/class/net/$NET_INTERFACE/statistics/tx_bytes)

# --- 组装JSON ---
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
curl -s -X POST -H "Content-Type: application/json" -d "$JSON_PAYLOAD" $BACKEND_URL
