#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=====================================================${NC}"
echo -e "${GREEN}          欢迎使用服务器监控面板一键安装脚本         ${NC}"
echo -e "${GREEN}=====================================================${NC}"
echo ""

# 函数：安装服务端
install_server() {
    echo -e "${YELLOW}开始安装服务端 (前端 + 后端)...${NC}"
    echo "--> 正在更新软件包并安装依赖 (Nginx, Node.js, Certbot)..."
    sudo apt-get update > /dev/null 2>&1
    sudo apt-get install -y nginx nodejs npm certbot python3-certbot-nginx > /dev/null 2>&1

    read -p "请输入您解析到本服务器的域名 (例如: monitor.yourdomain.com): " DOMAIN
    if [ -z "$DOMAIN" ]; then echo -e "${RED}错误：域名不能为空！${NC}"; exit 1; fi

    # 提示设置两种密码
    read -s -p "请为【网页端删除功能】设置一个强密码: " DEL_PASSWORD
    echo ""
    read -s -p "请为【被控端安装功能】设置一个强密码: " AGENT_PASSWORD
    echo ""
    if [ -z "$DEL_PASSWORD" ] || [ -z "$AGENT_PASSWORD" ]; then echo -e "${RED}错误：密码不能为空！${NC}"; exit 1; fi

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
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection 'upgrade';
proxy_set_header Host $host;
proxy_cache_bypass $http_upgrade;
}
location / {
try_files $uri $uri/ =404;
}
}
EOF
sudo ln -s -f "$NGINX_CONF" /etc/nginx/sites-enabled/
sudo nginx -t
    echo "--> 正在为 $DOMAIN 获取SSL证书..."
    read -p "请输入您的邮箱地址 (用于Let's Encrypt证书续订提醒): " EMAIL
    sudo certbot --nginx --agree-tos --redirect --non-interactive -m "$EMAIL" -d "$DOMAIN"

    echo "--> 正在部署前端面板..."
    sudo mkdir -p /var/www/monitor-frontend
    sudo curl -s -L "https://raw.githubusercontent.com/user/repo/main/frontend/index.html" -o /var/www/monitor-frontend/index.html
    sudo sed -i "s|https://monitor.yourdomain.com/api|https://$DOMAIN/api|g" /var/www/monitor-frontend/index.html
    
    echo "--> 正在部署后端API服务..."
    sudo mkdir -p /opt/monitor-backend
    cd /opt/monitor-backend
    sudo curl -s -L "https://raw.githubusercontent.com/user/repo/main/backend/server.js" -o server.js
    sudo curl -s -L "https://raw.githubusercontent.com/user/repo/main/backend/package.json" -o package.json
    sudo npm install > /dev/null 2>&1

    echo "--> 正在配置后端环境变量..."
    sudo tee /opt/monitor-backend/.env > /dev/null <<EOF
DELETE_PASSWORD=$DEL_PASSWORD
AGENT_INSTALL_PASSWORD=$AGENT_PASSWORD
EOF
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
    sudo systemctl restart nginx
    
    echo -e "${GREEN}=====================================================${NC}"
    echo -e "${GREEN}          服务端安装成功! 🎉${NC}"
    echo -e "您的监控面板地址: ${YELLOW}https://$DOMAIN${NC}"
    echo -e "请牢记您设置的两种密码！"
    echo -e "现在您可以去需要监控的服务器上，运行此脚本并选择'安装被控端'。"
    echo -e "${GREEN}=====================================================${NC}"
}

# 函数：安装被控端
install_agent() {
    echo -e "${YELLOW}开始安装被控端 (Agent)...${NC}"

    read -p "请输入您的后端API域名 (例如: https://monitor.yourdomain.com): " BACKEND_DOMAIN
    if [ -z "$BACKEND_DOMAIN" ]; then echo -e "${RED}错误：后端域名不能为空！${NC}"; exit 1; fi

    # 新增：验证安装密码
    read -s -p "请输入【被控端安装密码】: " AGENT_INSTALL_PASSWORD_INPUT
    echo ""
    
    echo "--> 正在验证安装密码..."
    VERIFY_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" -d "{\"password\":\"$AGENT_INSTALL_PASSWORD_INPUT\"}" "$BACKEND_DOMAIN/api/verify-agent-password")
    
    if [ "$VERIFY_STATUS" -ne 200 ]; then
        echo -e "${RED}错误：被控端安装密码错误或无法连接到后端！状态码: $VERIFY_STATUS${NC}"
        exit 1
    fi
    echo -e "${GREEN}密码验证成功！正在继续安装...${NC}"

    echo "--> 正在安装依赖 (sysstat, bc)..."
    sudo apt-get update > /dev/null 2>&1
    sudo apt-get install -y sysstat bc > /dev/null 2>&1

    read -p "请为当前服务器设置一个唯一的ID (例如: web-server-01): " SERVER_ID
    read -p "请输入当前服务器的名称 (例如: 亚太-Web服务器): " SERVER_NAME
    read -p "请输入当前服务器的位置 (例如: 新加坡): " SERVER_LOCATION
    
    NET_INTERFACE=\$(ip -o -4 route show to default | awk '{print \$5}')
    echo "--> 自动检测到网络接口为: \$NET_INTERFACE"

    echo "--> 正在部署Agent脚本..."
    sudo mkdir -p /opt/monitor-agent
    sudo curl -s -L "https://raw.githubusercontent.com/user/repo/main/agent/agent.sh" -o /opt/monitor-agent/agent.sh
    sudo chmod +x /opt/monitor-agent/agent.sh

    sudo sed -i "s|BACKEND_URL=.*|BACKEND_URL=\"\$BACKEND_DOMAIN/api/report\"|g" /opt/monitor-agent/agent.sh
    sudo sed -i "s|SERVER_ID=.*|SERVER_ID=\"\$SERVER_ID\"|g" /opt/monitor-agent/agent.sh
    sudo sed -i "s|SERVER_NAME=.*|SERVER_NAME=\"\$SERVER_NAME\"|g" /opt/monitor-agent/agent.sh
    sudo sed -i "s|SERVER_LOCATION=.*|SERVER_LOCATION=\"\$SERVER_LOCATION\"|g" /opt/monitor-agent/agent.sh
    sudo sed -i "s|NET_INTERFACE=.*|NET_INTERFACE=\"\$NET_INTERFACE\"|g" /opt/monitor-agent/agent.sh
    
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
sudo systemctl enable monitor-agent > /dev/null 2> /dev/null
sudo systemctl start monitor-agent
    echo -e "${GREEN}=====================================================${NC}"
    echo -e "${GREEN}          被控端Agent安装并启动成功! ✅${NC}"
    echo -e "现在您可以访问您的监控面板查看这台服务器的状态了。"
    echo -e "${GREEN}=====================================================${NC}"
}

# 主菜单
echo "请选择要执行的操作:"
echo "1) 安装服务端 (Frontend + Backend)"
echo "2) 安装被控端 (Agent)"
read -p "请输入选项 [1-2]: " choice

case $choice in
    1) install_server ;;
    2) install_agent ;;
    *) echo -e "${RED}错误：无效的选项！${NC}"; exit 1 ;;
esac
```
