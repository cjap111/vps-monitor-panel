#!/bin/bash

# =================================================================
#
#          一键式服务器监控面板安装/卸载/更新脚本 v2.1
#
# =================================================================

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# --- 脚本欢迎信息 ---
echo -e "${GREEN}=====================================================${NC}"
echo -e "${GREEN}      欢迎使用服务器监控面板一键安装/卸载/更新脚本V2.1      ${NC}"
echo -e "${GREEN}=====================================================${NC}"
echo ""

# --- 函数：安装/更新服务端 (Frontend + Backend) ---
install_server() {
    echo -e "${YELLOW}开始安装或更新服务端 (前端 + 后端)...${NC}"
    
    # 1. 更新并安装依赖
    echo "--> 正在更新软件包列表..."
    sudo apt-get update
    if [ $? -ne 0 ]; then
        echo -e "${RED}错误：'apt-get update' 失败。请检查您的apt源或网络连接。${NC}"
        exit 1
    fi

    echo "--> 正在检查并安装/更新依赖 (Nginx, Node.js, Certbot)..."
    dpkg -s nginx >/dev/null 2>&1 || sudo apt-get install -y nginx
    
    # 修复：更新Node.js到推荐的LTS版本 (20.x)
    echo "--> 正在检查并安装 Node.js (推荐版本 20.x LTS)..."
    if command -v node &> /dev/null; then
        NODE_VERSION=$(node -v | cut -d'v' -f2 | cut -d'.' -f1)
        if [ "$NODE_VERSION" -lt 20 ]; then
            echo "--> 检测到Node.js版本较低 ($NODE_VERSION)，将尝试升级到 20.x..."
            sudo apt-get remove -y nodejs npm
            curl -sL https://deb.nodesource.com/setup_20.x | sudo -E bash -
            sudo apt-get install -y nodejs
        else
            echo "--> Node.js 版本满足要求 (>=20.x)。"
        fi
    else
        echo "--> 未安装Node.js，正在安装 20.x LTS 版本..."
        curl -sL https://deb.nodesource.com/setup_20.x | sudo -E bash -
        sudo apt-get install -y nodejs
    fi

    dpkg -s certbot >/dev/null 2>&1 || sudo apt-get install -y certbot python3-certbot-nginx

    if [ $? -ne 0 ]; then
        echo -e "${RED}错误：依赖安装失败。请查看上面的错误信息来诊断问题。${NC}"
        exit 1
    fi

    # 设置服务器时区
    echo "--> 正在设置服务器时区为 Asia/Shanghai..."
    sudo timedatectl set-timezone Asia/Shanghai || echo -e "${YELLOW}警告：设置时区失败。这可能不会影响核心功能。${NC}"

    # 2. 获取用户输入
    local BACKEND_ENV_FILE="/opt/monitor-backend/.env"
    local OLD_DOMAIN=""
    local CURRENT_DEL_PASSWORD=""
    local CURRENT_AGENT_PASSWORD=""
    local OLD_EMAIL=""
    
    if [ -f "$BACKEND_ENV_FILE" ]; then
        OLD_DOMAIN=$(grep "^DOMAIN=" "$BACKEND_ENV_FILE" 2>/dev/null | cut -d= -f2)
        CURRENT_DEL_PASSWORD=$(grep "^DELETE_PASSWORD=" "$BACKEND_ENV_FILE" 2>/dev/null | cut -d= -f2)
        CURRENT_AGENT_PASSWORD=$(grep "^AGENT_INSTALL_PASSWORD=" "$BACKEND_ENV_FILE" 2>/dev/null | cut -d= -f2)
        OLD_EMAIL=$(grep "^CERTBOT_EMAIL=" "$BACKEND_ENV_FILE" 2>/dev/null | cut -d= -f2)
    fi

    read -p "请输入您解析到本服务器的域名 [默认: ${OLD_DOMAIN:-monitor.yourdomain.com}]: " DOMAIN
    DOMAIN=${DOMAIN:-$OLD_DOMAIN}
    if [ -z "$DOMAIN" ]; then
        echo -e "${RED}错误：域名不能为空！${NC}"
        exit 1
    fi

    read -s -p "请输入【网页端删除功能】的密码 [留空则不修改]: " DEL_PASSWORD_INPUT
    echo ""
    read -s -p "请输入【被控端安装功能】的密码 [留空则不修改]: " AGENT_PASSWORD_INPUT
    echo ""
    
    DEL_PASSWORD=${DEL_PASSWORD_INPUT:-$CURRENT_DEL_PASSWORD}
    AGENT_PASSWORD=${AGENT_PASSWORD_INPUT:-$CURRENT_AGENT_PASSWORD}

    if [ -z "$DEL_PASSWORD" ] || [ -z "$AGENT_PASSWORD" ]; then
        echo -e "${RED}错误：密码不能为空！首次安装必须设置。${NC}"
        exit 1
    fi

    # 3. 部署前端
    echo "--> 正在部署/更新前端面板..."
    sudo mkdir -p /var/www/monitor-frontend
    sudo curl -sL "https://raw.githubusercontent.com/cjap111/vps-monitor-panel/main/frontend/index.html" -o /var/www/monitor-frontend/index.html

    # 4. 配置Nginx进行HTTP验证
    echo "--> 正在配置Nginx进行HTTP验证..."
    NGINX_CONF="/etc/nginx/sites-available/$DOMAIN"
    sudo tee "$NGINX_CONF" > /dev/null <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF
    sudo ln -s -f "$NGINX_CONF" /etc/nginx/sites-enabled/
    sudo mkdir -p /var/www/certbot
    sudo chown www-data:www-data /var/www/certbot
    sudo nginx -t && sudo systemctl restart nginx

    # 5. 获取SSL证书
    echo "--> 正在为 $DOMAIN 获取或续订SSL证书..."
    read -p "请输入您的邮箱地址 (用于Let's Encrypt提醒) [默认: ${OLD_EMAIL:-user@example.com}]: " EMAIL
    EMAIL=${EMAIL:-$OLD_EMAIL}
    if [ -z "$EMAIL" ]; then
        echo -e "${RED}错误：邮箱不能为空！${NC}"
        exit 1
    fi
    
    if ! sudo certbot --nginx --agree-tos --non-interactive -m "$EMAIL" -d "$DOMAIN"; then
        echo -e "${RED}错误：Certbot未能成功获取SSL证书。请检查您的域名解析和防火墙设置。${NC}"
        exit 1
    fi

    # 6. 配置最终的Nginx HTTPS
    echo "--> 正在配置最终的Nginx HTTPS服务..."
    sudo tee "$NGINX_CONF" > /dev/null <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

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
        try_files \$uri \$uri/ /index.html;
    }
}
EOF
    sudo nginx -t && sudo systemctl restart nginx
    
    # 7. 部署后端
    echo "--> 正在部署/更新后端API服务..."
    sudo mkdir -p /opt/monitor-backend
    cd /opt/monitor-backend
    sudo curl -sL "https://raw.githubusercontent.com/cjap111/vps-monitor-panel/main/backend/server.js" -o server.js
    sudo curl -sL "https://raw.githubusercontent.com/cjap111/vps-monitor-panel/main/backend/package.json" -o package.json
    echo "--> 正在安装/更新后端依赖..."
    sudo npm install

    # 8. 创建或更新环境变量文件
    echo "--> 正在配置/更新后端环境变量..."
    sudo tee "$BACKEND_ENV_FILE" > /dev/null <<EOF
DELETE_PASSWORD=$DEL_PASSWORD
AGENT_INSTALL_PASSWORD=$AGENT_PASSWORD
DOMAIN=$DOMAIN
CERTBOT_EMAIL=$EMAIL
EOF

    # 9. 创建或更新Systemd服务
    echo "--> 正在创建/更新后台运行服务..."
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

    echo -e "${GREEN}=====================================================${NC}"
    echo -e "${GREEN}          服务端安装/更新成功! 🎉${NC}"
    echo -e "您的监控面板地址: ${YELLOW}https://$DOMAIN${NC}"
    echo -e "请牢记您设置的密码！"
    echo -e "现在您可以去需要监控的服务器上，运行此脚本并选择'安装被控端'。"
    echo -e "${GREEN}=====================================================${NC}"
}

# --- 函数：安装/更新被控端 ---
install_agent() {
    echo -e "${YELLOW}开始安装或更新被控端 (Agent)...${NC}"

    local AGENT_PATH="/opt/monitor-agent/agent.sh"
    local OLD_BACKEND_URL=""
    local OLD_SERVER_ID=""
    local OLD_SERVER_NAME=""
    local OLD_SERVER_LOCATION=""

    if [ -f "$AGENT_PATH" ]; then
        echo "--> 检测到现有Agent安装，将进行更新操作。"
        OLD_BACKEND_URL=$(grep "BACKEND_URL=" "$AGENT_PATH" 2>/dev/null | cut -d'"' -f2)
        OLD_SERVER_ID=$(grep "SERVER_ID=" "$AGENT_PATH" 2>/dev/null | cut -d'"' -f2)
        OLD_SERVER_NAME=$(grep "SERVER_NAME=" "$AGENT_PATH" 2>/dev/null | cut -d'"' -f2)
        OLD_SERVER_LOCATION=$(grep "SERVER_LOCATION=" "$AGENT_PATH" 2>/dev/null | cut -d'"' -f2)
    fi

    local OLD_BACKEND_DOMAIN=$(echo "$OLD_BACKEND_URL" | sed -E 's|/api/report$||')

    read -p "请输入您的后端API域名 (例如: https://monitor.yourdomain.com) [默认: $OLD_BACKEND_DOMAIN]: " BACKEND_DOMAIN
    BACKEND_DOMAIN=${BACKEND_DOMAIN:-$OLD_BACKEND_DOMAIN}
    if [ -z "$BACKEND_DOMAIN" ]; then
        echo -e "${RED}错误：后端域名不能为空！${NC}"
        exit 1
    fi
    
    read -s -p "请输入【被控端安装密码】: " AGENT_INSTALL_PASSWORD
    echo ""
    if [ -z "$AGENT_INSTALL_PASSWORD" ]; then
        echo -e "${RED}错误：密码不能为空！${NC}"
        exit 1
    fi

    echo "--> 正在验证安装密码..."
    VERIFY_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" -d "{\"password\":\"$AGENT_INSTALL_PASSWORD\"}" "$BACKEND_DOMAIN/api/verify-agent-password")
    
    if [ "$VERIFY_STATUS" -ne 200 ]; then
        echo -e "${RED}错误：被控端安装密码错误或无法连接到后端！状态码: $VERIFY_STATUS${NC}"
        exit 1
    fi
    echo -e "${GREEN}密码验证成功！${NC}"

    echo "--> 正在安装依赖 (sysstat, bc)..."
    sudo apt-get update >/dev/null
    sudo apt-get install -y sysstat bc >/dev/null

    read -p "请为当前服务器设置一个唯一的ID [默认: $OLD_SERVER_ID]: " SERVER_ID
    SERVER_ID=${SERVER_ID:-$OLD_SERVER_ID}
    read -p "请输入当前服务器的名称 [默认: $OLD_SERVER_NAME]: " SERVER_NAME
    SERVER_NAME=${SERVER_NAME:-$OLD_SERVER_NAME}
    read -p "请输入当前服务器的位置 [默认: $OLD_SERVER_LOCATION]: " SERVER_LOCATION
    SERVER_LOCATION=${SERVER_LOCATION:-$OLD_SERVER_LOCATION}
    
    if [ -z "$SERVER_ID" ] || [ -z "$SERVER_NAME" ] || [ -z "$SERVER_LOCATION" ]; then
        echo -e "${RED}错误：服务器ID、名称和位置均不能为空！${NC}"
        exit 1
    fi

    NET_INTERFACE=$(ip -o -4 route show to default | awk '{print $5}')
    echo "--> 自动检测到网络接口为: $NET_INTERFACE"

    echo "--> 正在部署/更新Agent脚本..."
    sudo mkdir -p /opt/monitor-agent
    sudo curl -sL "https://raw.githubusercontent.com/cjap111/vps-monitor-panel/main/agent/agent.sh" -o "$AGENT_PATH"
    sudo chmod +x "$AGENT_PATH"

    sudo sed -i "s|BACKEND_URL=.*|BACKEND_URL=\"$BACKEND_DOMAIN/api/report\"|g" "$AGENT_PATH"
    sudo sed -i "s|SERVER_ID=.*|SERVER_ID=\"$SERVER_ID\"|g" "$AGENT_PATH"
    sudo sed -i "s|SERVER_NAME=.*|SERVER_NAME=\"$SERVER_NAME\"|g" "$AGENT_PATH"
    sudo sed -i "s|SERVER_LOCATION=.*|SERVER_LOCATION=\"$SERVER_LOCATION\"|g" "$AGENT_PATH"
    sudo sed -i "s|NET_INTERFACE=.*|NET_INTERFACE=\"$NET_INTERFACE\"|g" "$AGENT_PATH"
    
    echo "--> 正在创建/更新后台上报服务..."
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
    sudo systemctl restart monitor-agent
    
    echo -e "${GREEN}=====================================================${NC}"
    echo -e "${GREEN}          被控端Agent安装/更新并启动成功! ✅${NC}"
    echo -e "现在您可以访问您的监控面板查看这台服务器的状态了。"
    echo -e "${GREEN}=====================================================${NC}"
}

# --- Function: Uninstall Server ---
uninstall_server() {
    echo -e "${YELLOW}开始卸载服务端...${NC}"
    read -p "请输入您安装时使用的域名 (例如: monitor.yourdomain.com): " DOMAIN
    if [ -z "$DOMAIN" ]; then
        echo -e "${RED}错误：域名不能为空！${NC}"
        exit 1
    fi

    echo -e "${RED}警告：此操作将删除所有服务端相关文件、服务和Nginx配置，包括所有流量统计数据。SSL证书将保留。${NC}"
    read -p "您确定要继续吗? [y/N]: " CONFIRM
    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
        echo "操作已取消。"
        exit 0
    fi

    sudo systemctl stop monitor-backend.service
    sudo systemctl disable monitor-backend.service
    sudo rm -rf /opt/monitor-backend
    sudo rm -f /etc/systemd/system/monitor-backend.service
    sudo systemctl stop nginx
    sudo rm -f "/etc/nginx/sites-available/$DOMAIN"
    sudo rm -f "/etc/nginx/sites-enabled/$DOMAIN"
    sudo rm -rf /var/www/monitor-frontend
    sudo rm -rf /var/www/certbot
    sudo systemctl daemon-reload
    sudo systemctl restart nginx
    
    echo -e "${GREEN}=====================================================${NC}"
    echo -e "${GREEN}          服务端卸载成功! ✅${NC}"
    echo -e "SSL证书文件仍保留，您可以使用 'sudo certbot delete --cert-name $DOMAIN' 手动删除。 "
    echo -e "${GREEN}=====================================================${NC}"
}

# --- Function: Uninstall Agent ---
uninstall_agent() {
    echo -e "${YELLOW}开始卸载被控端...${NC}"
    read -p "您确定要停止并删除本服务器上的监控Agent吗? [y/N]: " CONFIRM
    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
        echo "操作已取消。"
        exit 0
    fi

    sudo systemctl stop monitor-agent.service
    sudo systemctl disable monitor-agent.service
    sudo rm -rf /opt/monitor-agent
    sudo rm -f /etc/systemd/system/monitor-agent.service
    sudo systemctl daemon-reload
    
    echo -e "${GREEN}=====================================================${NC}"
    echo -e "${GREEN}          被控端Agent卸载成功! ✅${NC}"
    echo -e "请记得到您的监控面板网页端手动删除此服务器的记录。"
    echo -e "${GREEN}=====================================================${NC}"
}

# --- Main Menu ---
if [ "$#" -gt 0 ]; then
    case $1 in
        1) install_server ;;
        2) install_agent ;;
        3) uninstall_server ;;
        4) uninstall_agent ;;
        *) echo -e "${RED}错误：无效的参数！${NC}" ;;
    esac
else
    echo "请选择要执行的操作: (再次运行本脚本即可安装或更新)"
    echo "1) 安装/更新服务端 (Frontend + Backend)"
    echo "2) 安装/更新被控端 (Agent)"
    echo -e "${YELLOW}3) 卸载服务端${NC}"
    echo -e "${YELLOW}4) 卸载被控端${NC}"
    read -p "请输入选项 [1-4]: " choice

    case $choice in
        1) install_server ;;
        2) install_agent ;;
        3) uninstall_server ;;
        4) uninstall_agent ;;
        *) echo -e "${RED}错误：无效的选项！${NC}" ;;
    esac
fi
