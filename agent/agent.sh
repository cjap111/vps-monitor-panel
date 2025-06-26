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

# 获取CPU型号
# 尝试使用 lscpu 获取 CPU 型号，如果不存在则回退到 /proc/cpuinfo
CPU_MODEL=$(lscpu | grep "Model name" | cut -d: -f2 | xargs || cat /proc/cpuinfo | grep 'model name' | head -n 1 | cut -d: -f2 | xargs || echo "Unknown CPU")

# 获取内存信息 (单位：兆字节 MB)
MEM_INFO=$(free -m | grep Mem)
MEM_TOTAL=$(echo $MEM_INFO | awk '{print $2}' || echo 0)
MEM_USED=$(echo $MEM_INFO | awk '{print $3}' || echo 0)

# 获取内存型号
# 尝试使用 dmidecode 获取内存制造商和部件号作为型号，需要root权限且可能系统未安装此工具
# 如果没有 dmidecode 或没有足够权限，则显示 "Unknown Memory Model"
# 仅获取第一个内存模块的信息以简化处理
MEM_MODEL=$(sudo dmidecode -t 17 2>/dev/null | awk '/Size:/{s=$2" "$3}/Manufacturer:/{m=$2}/Part Number:/{p=$3; printf "%s %s %s\n", m, p, s; exit}' || echo "Unknown Memory Model")
MEM_MODEL=${MEM_MODEL:-"Unknown Memory Model"} # 确保变量不为空

# 获取磁盘信息 (单位：兆字节 MB)
# 使用 -BM 参数获取M单位的磁盘大小，更稳定
DISK_INFO=$(df -BM / | tail -n 1)
# 从df输出中提取总空间，并去除'M'单位
DISK_TOTAL=$(echo $DISK_INFO | awk '{print $2}' | sed 's/M//' || echo 0)
# 从df输出中提取已用空间，并去除'M'单位
DISK_USED=$(echo $DISK_INFO | awk '{print $3}' | sed 's/M//' || echo 0)

# 获取硬盘型号
# 1. 确定根分区对应的块设备
ROOT_PARTITION=$(df -P / | tail -n 1 | awk '{print $1}')
# 2. 从分区路径中提取基础设备名 (例如 /dev/sda 从 /dev/sda1, 或 /dev/nvme0n1 从 /dev/nvme0n1p1)
# 针对常见的 /dev/sdXN 和 /dev/nvmeXnYpN 格式
if echo "$ROOT_PARTITION" | grep -q "nvme"; then
    ROOT_DEV_BASE=$(echo "$ROOT_PARTITION" | sed -E 's/p[0-9]+$//') # 移除 NVMe 分区号
elif echo "$ROOT_PARTITION" | grep -q "/dev/sd"; then
    ROOT_DEV_BASE=$(echo "$ROOT_PARTITION" | sed -E 's/[0-9]+$//') # 移除 /dev/sdX 分区号
else
    ROOT_DEV_BASE="$ROOT_PARTITION" # 其他情况直接使用
fi

# 3. 使用 lsblk 获取该设备的型号
# 确保 ROOT_DEV_BASE 是一个有效的设备路径 (例如 /dev/sda)
if [ -b "$ROOT_DEV_BASE" ]; then # 检查是否是块设备
    DISK_MODEL=$(lsblk -no MODEL "$ROOT_DEV_BASE" 2>/dev/null | head -n 1 | xargs || echo "Unknown Disk Model")
else
    DISK_MODEL="Unknown Disk Model"
fi
DISK_MODEL=${DISK_MODEL:-"Unknown Disk Model"} # 确保变量不为空

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

# 获取系统在线时间 (秒)
SYSTEM_UPTIME_SECONDS=$(awk -F. '{print $1}' /proc/uptime || echo 0)

# --- 组装JSON数据 ---
# 注意: JSON中不能使用#作为注释，已移除
JSON_PAYLOAD=$(cat <<EOF
{
  "id": "$SERVER_ID",
  "name": "$SERVER_NAME",
  "location": "$SERVER_LOCATION",
  "os": "$OS",
  "cpu": $CPU_USAGE,
  "cpuModel": "$CPU_MODEL",
  "mem": { "total": $MEM_TOTAL, "used": $MEM_USED },
  "memModel": "$MEM_MODEL",
  "disk": { "total": $DISK_TOTAL, "used": $DISK_USED },
  "diskModel": "$DISK_MODEL",
  "net": { "up": $NET_UP_BPS, "down": $NET_DOWN_BPS },
  "rawTotalNet": { "up": $RAW_TOTAL_NET_UP, "down": $RAW_TOTAL_NET_UP },
  "systemUptime": $SYSTEM_UPTIME_SECONDS
}
EOF
)

# --- 上报数据 ---
# 使用curl发送POST请求到后端API
curl -s -X POST -H "Content-Type: application/json" -d "$JSON_PAYLOAD" $BACKEND_URL
