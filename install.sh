#!/bin/bash

# =================================================================
#
#          一键式服务器监控面板安装/卸载脚本 v1.4
#
# =================================================================

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# --- 脚本欢迎信息 ---
echo -e "${GREEN}=====================================================${NC}"
echo -e "${GREEN}      欢迎使用服务器监控面板一键安装/卸载脚本      ${NC}"
echo -e "${GREEN}=====================================================${NC}"
echo ""

# --- 函数：安装服务端 (Frontend + Backend) ---
install_server() {
    echo -e "${YELLOW}开始安装服务端 (前端 + 后端)...${NC}"
    
    # 1. 更新并安装依赖 (已移除静默模式以显示详细日志)
    echo "--> 正在更新软件包列表..."
    sudo apt-get update
    if [ $? -ne 0 ]; then
        echo -e "${RED}错误：'apt-get update' 失败。请检查您的apt源或网络连接。${NC}"
        exit 1
    fi

    echo "--> 正在安装依赖 (Nginx, Node.js, Certbot)..."
    sudo apt-get install -y nginx nodejs npm certbot python3-certbot-nginx
    if [ $? -ne 0 ]; then
        echo -e "${RED}错误：依赖安装失败。请查看上面的错误信息来诊断问题。${NC}"
        exit 1
    fi

    # 2. 获取用户输入
    read -p "请输入您解析到本服务器的域名 (例如: monitor.yourdomain.com): " DOMAIN
    if [ -z "$DOMAIN" ]; then
        echo -e "${RED}错误：域名不能为空！${NC}"
        exit 1
    fi
    
    read -s -p "请为【网页端删除功能】设置一个强密码: " DEL_PASSWORD
    echo ""
    read -s -p "请为【被控端安装功能】设置一个强密码: " AGENT_PASSWORD
    echo ""
    if [ -z "$DEL_PASSWORD" ] || [ -z "$AGENT_PASSWORD" ]; then
        echo -e "${RED}错误：密码不能为空！${NC}"
        exit 1
    fi
    
    # 3. 配置Nginx
    echo "--> 正在配置Nginx反向代理..."
    NGINX_CONF="/etc/nginx/sites-available/$DOMAIN"
    sudo tee "$NGINX_CONF" > /dev/null <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    root /var/www/monitor-frontend;
    index index.html;

    location /api {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
    }
    
    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
    sudo ln -s -f "$NGINX_CONF" /etc/nginx/sites-enabled/
    sudo nginx -t

    # 4. 获取SSL证书
    echo "--> 正在为 $DOMAIN 获取SSL证书..."
    read -p "请输入您的邮箱地址 (用于Let's Encrypt证书续订提醒): " EMAIL
    sudo certbot --nginx --agree-tos --redirect --non-interactive -m "$EMAIL" -d "$DOMAIN"

    # 5. 部署前端
    echo "--> 正在部署前端面板..."
    sudo mkdir -p /var/www/monitor-frontend
    # !! 注意：请将下面的 user/repo 替换为您自己的GitHub用户名和仓库名
    sudo curl -s -L "https://raw.githubusercontent.com/user/repo/main/frontend/index.html" -o /var/www/monitor-frontend/index.html
    sudo sed -i "s|https://monitor.yourdomain.com/api|https://$DOMAIN/api|g" /var/www/monitor-frontend/index.html
    
    # 6. 部署后端
    echo "--> 正在部署后端API服务..."
    sudo mkdir -p /opt/monitor-backend
    cd /opt/monitor-backend
    # !! 注意：请将下面的 user/repo 替换为您自己的GitHub用户名和仓库名
    sudo curl -s -L "https://raw.githubusercontent.com/user/repo/main/backend/server.js" -o server.js
    sudo curl -s -L "https://raw.githubusercontent.com/user/repo/main/backend/package.json" -o package.json
    sudo npm install

    # 7. 创建环境变量文件
    echo "--> 正在配置后端环境变量..."
    sudo tee /opt/monitor-backend/.env > /dev/null <<EOF
DELETE_PASSWORD=$DEL_PASSWORD
AGENT_INSTALL_PASSWORD=$AGENT_PASSWORD
EOF

    # 8. 创建Systemd服务
    echo "--> 正在创建后台运行服务..."
    sudo tee /etc/systemd/system/monitor-backend.service > /dev/null <<EOF
[Unit]
Description=Monitor Backend Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/monitor-backend
EnvironmentFile=/opt/monitor-backend/.env
ExecStart=/usr/bin/node server.js
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable monitor-backend > /dev/null 2>&1
    sudo systemctl restart monitor-backend

    # 9. 重启Nginx
    sudo systemctl restart nginx
    
    echo -e "${GREEN}=====================================================${NC}"
    echo -e "${GREEN}          服务端安装成功! 🎉${NC}"
    echo -e "您的监控面板地址: ${YELLOW}https://$DOMAIN${NC}"
    echo -e "请牢记您设置的两种密码！"
    echo -e "现在您可以去需要监控的服务器上，运行此脚本并选择'安装被控端'。"
    echo -e "${GREEN}=====================================================${NC}"
}

# --- 函数：安装被控端 (Agent) ---
install_agent() {
    echo -e "${YELLOW}开始安装被控端 (Agent)...${NC}"

    # 1. 获取用户输入
    read -p "请输入您的后端API域名 (例如: https://monitor.yourdomain.com): " BACKEND_DOMAIN
    if [ -z "$BACKEND_DOMAIN" ]; then
        echo -e "${RED}错误：后端域名不能为空！${NC}"
        exit 1
    fi

    read -s -p "请输入【被控端安装密码】: " AGENT_INSTALL_PASSWORD_INPUT
    echo ""
    
    # 2. 验证密码
    echo "--> 正在验证安装密码..."
    VERIFY_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" -d "{\"password\":\"$AGENT_INSTALL_PASSWORD_INPUT\"}" "$BACKEND_DOMAIN/api/verify-agent-password")
    
    if [ "$VERIFY_STATUS" -ne 200 ]; then
        echo -e "${RED}错误：被控端安装密码错误或无法连接到后端！状态码: $VERIFY_STATUS${NC}"
        exit 1
    fi
    echo -e "${GREEN}密码验证成功！正在继续安装...${NC}"

    # 3. 安装依赖 (已移除静默模式)
    echo "--> 正在安装依赖 (sysstat, bc)..."
    sudo apt-get update
    sudo apt-get install -y sysstat bc
    if [ $? -ne 0 ]; then
        echo -e "${RED}错误：依赖 'sysstat' 或 'bc' 安装失败。${NC}"
        exit 1
    fi

    # 4. 获取服务器信息
    read -p "请为当前服务器设置一个唯一的ID (例如: web-server-01): " SERVER_ID
    read -p "请输入当前服务器的名称 (例如: 亚太-Web服务器): " SERVER_NAME
    read -p "请输入当前服务器的位置 (例如: 新加坡): " SERVER_LOCATION
    
    NET_INTERFACE=$(ip -o -4 route show to default | awk '{print $5}')
    echo "--> 自动检测到网络接口为: $NET_INTERFACE"

    # 5. 部署Agent脚本
    echo "--> 正在部署Agent脚本..."
    sudo mkdir -p /opt/monitor-agent
    # !! 注意：请将下面的 user/repo 替换为您自己的GitHub用户名和仓库名
    sudo curl -s -L "https://raw.githubusercontent.com/user/repo/main/agent/agent.sh" -o /opt/monitor-agent/agent.sh
    sudo chmod +x /opt/monitor-agent/agent.sh

    # 6. 更新Agent配置
    sudo sed -i "s|BACKEND_URL=.*|BACKEND_URL=\"$BACKEND_DOMAIN/api/report\"|g" /opt/monitor-agent/agent.sh
    sudo sed -i "s|SERVER_ID=.*|SERVER_ID=\"$SERVER_ID\"|g" /opt/monitor-agent/agent.sh
    sudo sed -i "s|SERVER_NAME=.*|SERVER_NAME=\"$SERVER_NAME\"|g" /opt/monitor-agent/agent.sh
    sudo sed -i "s|SERVER_LOCATION=.*|SERVER_LOCATION=\"$SERVER_LOCATION\"|g" /opt/monitor-agent/agent.sh
    sudo sed -i "s|NET_INTERFACE=.*|NET_INTERFACE=\"$NET_INTERFACE\"|g" /opt/monitor-agent/agent.sh
    
    # 7. 创建Systemd服务
    echo "--> 正在创建后台上报服务..."
    sudo tee /etc/systemd/system/monitor-agent.service > /dev/null <<EOF
[Unit]
Description=Monitor Agent
After=network.target

[Service]
Type=simple
ExecStart=/bin/bash -c 'while true; do /opt/monitor-agent/agent.sh; sleep 5; done'
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable monitor-agent > /dev/null 2>&1
    sudo systemctl start monitor-agent
    
    echo -e "${GREEN}=====================================================${NC}"
    echo -e "${GREEN}          被控端Agent安装并启动成功! ✅${NC}"
    echo -e "现在您可以访问您的监控面板查看这台服务器的状态了。"
    echo -e "${GREEN}=====================================================${NC}"
}

# --- 函数：卸载服务端 ---
uninstall_server() {
    echo -e "${YELLOW}开始卸载服务端...${NC}"
    read -p "请输入您安装时使用的域名 (例如: monitor.yourdomain.com): " DOMAIN
    if [ -z "$DOMAIN" ]; then
        echo -e "${RED}错误：域名不能为空！${NC}"
        exit 1
    fi

    echo -e "${RED}警告：此操作将删除所有服务端相关文件和服务，但会保留SSL证书。${NC}"
    read -p "您确定要继续吗? [y/N]: " CONFIRM
    if [[ "$CONFIRM" != "y" ]]; then
        echo "操作已取消。"
        exit 0
    fi

    # 1. 停止并禁用后端服务
    echo "--> 正在停止并禁用后端服务..."
    sudo systemctl stop monitor-backend.service
    sudo systemctl disable monitor-backend.service > /dev/null 2>&1
    
    # 2. 删除后端文件和服务文件
    echo "--> 正在删除后端文件..."
    sudo rm -rf /opt/monitor-backend
    sudo rm -f /etc/systemd/system/monitor-backend.service
    
    # 3. 停止Nginx
    echo "--> 正在停止Nginx..."
    sudo systemctl stop nginx
    
    # 4. 删除Nginx配置
    echo "--> 正在删除Nginx配置..."
    sudo rm -f "/etc/nginx/sites-available/$DOMAIN"
    sudo rm -f "/etc/nginx/sites-enabled/$DOMAIN"
    
    # 5. 删除前端文件
    echo "--> 正在删除前端文件..."
    sudo rm -rf /var/www/monitor-frontend

    # 6. 重载Systemd并重启Nginx
    echo "--> 正在重载服务并重启Nginx..."
    sudo systemctl daemon-reload
    sudo systemctl restart nginx
    
    echo -e "${GREEN}=====================================================${NC}"
    echo -e "${GREEN}          服务端卸载成功! ✅${NC}"
    echo -e "SSL证书文件保留在系统中，您可以使用 'sudo certbot delete --cert-name $DOMAIN' 手动删除。"
    echo -e "${GREEN}=====================================================${NC}"
}

# --- 函数：卸载被控端 ---
uninstall_agent() {
    echo -e "${YELLOW}开始卸载被控端...${NC}"
    echo -e "${RED}警告：此操作将停止并删除本服务器上的监控Agent。${NC}"
    read -p "您确定要继续吗? [y/N]: " CONFIRM
    if [[ "$CONFIRM" != "y" ]]; then
        echo "操作已取消。"
        exit 0
    fi

    # 1. 停止并禁用Agent服务
    echo "--> 正在停止并禁用Agent服务..."
    sudo systemctl stop monitor-agent.service
    sudo systemctl disable monitor-agent.service > /dev/null 2>&1
    
    # 2. 删除Agent文件和服务文件
    echo "--> 正在删除Agent文件..."
    sudo rm -rf /opt/monitor-agent
    sudo rm -f /etc/systemd/system/monitor-agent.service
    
    # 3. 重载Systemd
    echo "--> 正在重载服务..."
    sudo systemctl daemon-reload
    
    echo -e "${GREEN}=====================================================${NC}"
    echo -e "${GREEN}          被控端Agent卸载成功! ✅${NC}"
    echo -e "请记得到您的监控面板网页端手动删除此服务器。 "
    echo -e "${GREEN}=====================================================${NC}"
}

# --- 主菜单 ---
echo "请选择要执行的操作:"
echo "1) 安装服务端 (Frontend + Backend)"
echo "2) 安装被控端 (Agent)"
echo -e "${YELLOW}3) 卸载服务端${NC}"
echo -e "${YELLOW}4) 卸载被控端${NC}"
read -p "请输入选项 [1-4]: " choice

case $choice in
    1)
        install_server
        ;;
    2)
        install_agent
        ;;
    3)
        uninstall_server
        ;;
    4)
        uninstall_agent
        ;;
    *)
        echo -e "${RED}错误：无效的选项！${NC}"
        exit 1
        ;;
esac
