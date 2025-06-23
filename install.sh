#!/bin/bash

# =================================================================
#
#          一键式服务器监控面板安装/卸载/更新脚本 v1.7 (定制版)
#
# =================================================================

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'\
NC='\033[0m' # No Color

# --- 脚本欢迎信息 ---
echo -e "${GREEN}=====================================================${NC}"
echo -e "${GREEN}      欢迎使用服务器监控面板一键安装/卸载/更新脚本      ${NC}"
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
    dpkg -s nodejs >/dev/null 2>&1 || sudo apt-get install -y nodejs npm
    dpkg -s certbot >/dev/null 2>&1 || sudo apt-get install -y certbot python3-certbot-nginx

    if [ $? -ne 0 ]; then
        echo -e "${RED}错误：依赖安装失败。请查看上面的错误信息来诊断问题。${NC}"
        exit 1
    fi

    # 2. 获取用户输入 (如果是更新，尝试读取旧配置，否则提示输入)
    local BACKEND_ENV_FILE="/opt/monitor-backend/.env"
    local OLD_DOMAIN_FROM_ENV="" 
    local CURRENT_DEL_PASSWORD=""
    local CURRENT_AGENT_PASSWORD=""
    local OLD_EMAIL=""
    local ENV_FILE_EXISTS=false

    # 尝试从后端服务的 .env 文件中读取旧配置，并抑制grep的错误输出
    if [ -f "$BACKEND_ENV_FILE" ]; then
        OLD_DOMAIN_FROM_ENV=$(grep "^DOMAIN=" "$BACKEND_ENV_FILE" 2>/dev/null | cut -d= -f2)
        CURRENT_DEL_PASSWORD=$(grep "^DELETE_PASSWORD=" "$BACKEND_ENV_FILE" 2>/dev/null | cut -d= -f2)
        CURRENT_AGENT_PASSWORD=$(grep "^AGENT_INSTALL_PASSWORD=" "$BACKEND_ENV_FILE" 2>/dev/null | cut -d= -f2)
        OLD_EMAIL=$(grep "^CERTBOT_EMAIL=" "$BACKEND_ENV_FILE" 2>/dev/null | cut -d= -f2)
        ENV_FILE_EXISTS=true
    fi

    local DOMAIN_VALIDATED=false
    while [ "$DOMAIN_VALIDATED" == "false" ]; do
        local USER_INPUT_DOMAIN=""

        if [ -n "$OLD_DOMAIN_FROM_ENV" ] && \
           ! [[ "$OLD_DOMAIN_FROM_ENV" == "server_name" ]] && \
           [[ "$OLD_DOMAIN_FROM_ENV" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            read -p "检测到旧域名: ${OLD_DOMAIN_FROM_ENV}。是否继续使用此域名? (y/N): " USE_OLD_DOMAIN_PROMPT
            if [[ "$USE_OLD_DOMAIN_PROMPT" == "y" || "$USE_OLD_DOMAIN_PROMPT" == "Y" ]]; then
                DOMAIN="$OLD_DOMAIN_FROM_ENV"
                echo "继续使用域名: $DOMAIN"
                DOMAIN_VALIDATED=true
                break
            else
                read -p "请输入新的域名 (例如: monitor.yourdomain.com): " USER_INPUT_DOMAIN
            fi
        else
            read -p "请输入您解析到本服务器的域名 (例如: monitor.yourdomain.com): " USER_INPUT_DOMAIN
        fi

        DOMAIN="$USER_INPUT_DOMAIN"

        if [ -z "$DOMAIN" ]; then
            echo -e "${RED}错误：域名不能为空！请重新输入。${NC}"
        elif [[ "$DOMAIN" == *" "* ]]; then
            echo -e "${RED}错误：域名不能包含空格！请重新输入。${NC}"
        elif [[ "$DOMAIN" == "server_name" ]]; then
            echo -e "${RED}错误：域名不能是 'server_name'。请输入您的实际域名。${NC}"
        elif ! [[ "$DOMAIN" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            echo -e "${RED}错误：域名格式不正确。请确保只使用字母、数字、点和破折号，并包含有效顶级域名（如 .com, .net）。${NC}"
        else
            DOMAIN_VALIDATED=true
        fi
    done

    # 密码输入部分
    echo ""
    if [ "$ENV_FILE_EXISTS" = false ] || ( [ -z "$CURRENT_DEL_PASSWORD" ] && [ -z "$CURRENT_AGENT_PASSWORD" ] ); then
        echo -e "${YELLOW}由于是首次安装或未检测到旧密码，请务必设置以下密码！${NC}"
        read -s -p "请为【网页端删除功能】设置一个强密码: " DEL_PASSWORD_INPUT
        echo ""
        read -s -p "请为【被控端安装功能】设置一个强密码: " AGENT_PASSWORD_INPUT
        echo ""
        DEL_PASSWORD="$DEL_PASSWORD_INPUT"
        AGENT_PASSWORD="$AGENT_PASSWORD_INPUT"
    else
        echo -e "${YELLOW}检测到现有密码。如果需要修改，请输入新密码；留空表示不修改（保持旧密码）。${NC}"
        read -s -p "请为【网页端删除功能】设置一个强密码 (当前: ${CURRENT_DEL_PASSWORD:+已设置}): " DEL_PASSWORD_INPUT
        echo ""
        read -s -p "请为【被控端安装功能】设置一个强密码 (当前: ${CURRENT_AGENT_PASSWORD:+已设置}): " AGENT_PASSWORD_INPUT
        echo ""
        DEL_PASSWORD="${DEL_PASSWORD_INPUT:-$CURRENT_DEL_PASSWORD}"
        AGENT_PASSWORD="${AGENT_PASSWORD_INPUT:-$CURRENT_AGENT_PASSWORD}"
    fi

    if [ -z "$DEL_PASSWORD" ] || [ -z "$AGENT_PASSWORD" ]; then
        echo -e "${RED}错误：密码不能为空！首次安装或修改密码时，请务必设置！${NC}"
        exit 1
    fi
    
    # 3. 配置Nginx
    echo "--> 正在配置Nginx反向代理..."
    NGINX_CONF="/etc/nginx/sites-available/$DOMAIN"
    sudo tee "$NGINX_CONF" > /dev/null <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri; # 强制 HTTP 跳转到 HTTPS
}

server {
    listen 443 ssl;
    server_name $DOMAIN;

    # Certbot 默认的证书路径
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    # 推荐的 SSL 协议和密码套件，增强安全性
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers on;

    root /var/www/monitor-frontend; # 前端文件的根目录
    index index.html; # 默认索引文件

    location /api {
        proxy_pass http://127.0.0.1:3000; # 将 /api 请求代理到 Node.js 后端
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
        # 增加代理超时设置，防止后端响应慢导致连接关闭
        proxy_connect_timeout 600;
        proxy_send_timeout 600;
        proxy_read_timeout 600;
    }
    
    location / {
        # 对于前端路由，将所有未找到的文件和目录的请求重定向到 index.html
        try_files \$uri \$uri/ /index.html; 
    }
}
EOF
    # 移除旧域名对应的 Nginx 符号链接（如果域名发生变化）
    if [ -n "$OLD_DOMAIN_FROM_ENV" ] && [ "$OLD_DOMAIN_FROM_ENV" != "$DOMAIN" ] && [ -f "/etc/nginx/sites-enabled/$OLD_DOMAIN_FROM_ENV" ]; then
        echo "--> 检测到域名更改，正在移除旧Nginx符号链接..."
        sudo rm -f "/etc/nginx/sites-enabled/$OLD_DOMAIN_FROM_ENV"
    fi
    sudo ln -s -f "$NGINX_CONF" /etc/nginx/sites-enabled/
    sudo nginx -t

    # 4. 获取SSL证书 (如果证书不存在或需要续订)
    echo "--> 正在为 $DOMAIN 获取或续订SSL证书..."

    # 检查 Certbot 是否已为该域名配置 HTTPS
    # Certbot 0.28 及以后版本会在证书成功部署后，自动修改 Nginx 配置文件添加 443 端口配置
    if sudo certbot certificates -d "$DOMAIN" | grep -q "VALID"; then
        echo -e "${GREEN}检测到现有有效的SSL证书，跳过新证书申请。Certbot会自动处理续订。${NC}"
        EMAIL="${OLD_EMAIL}" # 如果有旧邮箱，则保留
    else
        local EMAIL_INPUT=""
        if [ -n "$OLD_EMAIL" ]; then
            read -p "检测到旧邮箱地址: ${OLD_EMAIL}。是否继续使用此邮箱? (y/N): " USE_OLD_EMAIL_PROMPT
            if [[ "$USE_OLD_EMAIL_PROMPT" == "y" || "$USE_OLD_EMAIL_PROMPT" == "Y" ]]; then
                EMAIL="$OLD_EMAIL"
                echo "继续使用邮箱: $EMAIL"
            else
                read -p "请输入您的邮箱地址 (用于Let's Encrypt证书续订提醒): " EMAIL_INPUT
            fi
        else
            read -p "请输入您的邮箱地址 (用于Let's Encrypt证书续订提醒): " EMAIL_INPUT
        fi

        EMAIL="${EMAIL_INPUT:-$OLD_EMAIL}" # 使用新输入，如果没有则回退到旧邮箱
        if [ -z "$EMAIL" ]; then
            echo -e "${RED}错误：邮箱地址不能为空！申请SSL证书需要提供邮箱。${NC}"
            exit 1 # 邮箱是申请新证书的必要条件
        fi

        # 注意：此处移除了 --redirect 参数，因为我们已经在Nginx配置中手动添加了跳转
        sudo certbot --nginx --agree-tos --non-interactive -m "$EMAIL" -d "$DOMAIN"
    fi

    # 5. 部署前端 (强制更新)
    echo "--> 正在部署/更新前端面板..."
    sudo mkdir -p /var/www/monitor-frontend
    sudo curl -s -L "https://raw.githubusercontent.com/cjap111/vps-monitor-panel/main/frontend/index.html" -o /var/www/monitor-frontend/index.html
    # 替换前端HTML中的API_ENDPOINT，使其指向当前域名
    sudo sed -i "s|https://monitor.yourdomain.com/api|https://$DOMAIN/api|g" /var/www/monitor-frontend/index.html
    
    # 6. 部署后端 (强制更新)
    echo "--> 正在部署/更新后端API服务..."
    sudo mkdir -p /opt/monitor-backend
    cd /opt/monitor-backend
    sudo curl -s -L "https://raw.githubusercontent.com/cjap111/vps-monitor-panel/main/backend/server.js" -o server.js
    sudo curl -s -L "https://raw.githubusercontent.com/cjap111/vps-monitor-panel/main/backend/package.json" -o package.json
    echo "--> 正在安装/更新后端依赖..."
    sudo npm install

    # 7. 创建或更新环境变量文件
    echo "--> 正在配置/更新后端环境变量..."
    sudo tee "$BACKEND_ENV_FILE" > /dev/null <<EOF
DELETE_PASSWORD=$DEL_PASSWORD
AGENT_INSTALL_PASSWORD=$AGENT_PASSWORD
DOMAIN=$DOMAIN # 显式保存域名到 .env 文件
${EMAIL:+CERTBOT_EMAIL=$EMAIL} # 如果邮箱已设置，则保存到 .env
EOF

    # 8. 创建或更新Systemd服务
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

    # 9. 重启Nginx
    sudo systemctl restart nginx
    
    echo -e "${GREEN}=====================================================${NC}"
    echo -e "${GREEN}          服务端安装/更新成功! 🎉${NC}"
    echo -e "您的监控面板地址: ${YELLOW}https://$DOMAIN${NC}"
    echo -e "请牢记您设置的两种密码！"
    echo -e "现在您可以去需要监控的服务器上，运行此脚本并选择'安装被控端'来进行安装或更新。"
    echo -e "${GREEN}=====================================================${NC}"
}

# --- 函数：安装/更新被控端 (Agent) ---
install_agent() {
    echo -e "${YELLOW}开始安装或更新被控端 (Agent)...${NC}"

    local AGENT_PATH="/opt/monitor-agent/agent.sh"
    local AGENT_SERVICE_PATH="/etc/systemd/system/monitor-agent.service"
    local IS_UPDATE=false
    local OLD_SERVER_ID=""
    local OLD_SERVER_NAME=""
    local OLD_SERVER_LOCATION=""
    local OLD_BACKEND_URL=""
    local OLD_NET_INTERFACE=""

    if [ -f "$AGENT_PATH" ] && [ -f "$AGENT_SERVICE_PATH" ]; then
        IS_UPDATE=true
        echo "--> 检测到现有Agent安装，将进行更新操作。"
        # 停止服务以避免冲突
        echo "--> 正在停止现有Agent服务..."
        sudo systemctl stop monitor-agent.service > /dev/null 2>&1
        sudo systemctl disable monitor-agent.service > /dev/null 2>&1
        
        # 尝试从旧脚本中读取配置，并抑制grep的错误输出
        OLD_BACKEND_URL=$(grep "BACKEND_URL=" "$AGENT_PATH" 2>/dev/null | cut -d\" -f2)
        OLD_SERVER_ID=$(grep "SERVER_ID=" "$AGENT_PATH" 2>/dev/null | cut -d\" -f2)
        OLD_SERVER_NAME=$(grep "SERVER_NAME=" "$AGENT_PATH" 2>/dev/null | cut -d\" -f2)
        OLD_SERVER_LOCATION=$(grep "SERVER_LOCATION=" "$AGENT_PATH" 2>/dev/null | cut -d\" -f2)
        OLD_NET_INTERFACE=$(grep "NET_INTERFACE=" "$AGENT_PATH" 2>/dev/null | cut -d\" -f2)

        # 从完整 URL 中提取域名
        OLD_BACKEND_DOMAIN=$(echo "$OLD_BACKEND_URL" | sed 's#/api/report##')

        if [ -n "$OLD_BACKEND_DOMAIN" ]; then
            echo "--> 检测到旧的后端域名: $OLD_BACKEND_DOMAIN"
        fi
        if [ -n "$OLD_SERVER_ID" ]; then
            echo "--> 检测到旧的服务器ID: $OLD_SERVER_ID"
        fi
        if [ -n "$OLD_SERVER_NAME" ]; then
            echo "--> 检测到旧的服务器名称: $OLD_SERVER_NAME"
        fi
    fi

    # 1. 获取用户输入
    local BACKEND_DOMAIN_INPUT=""
    if [ -n "$OLD_BACKEND_DOMAIN" ]; then
        read -p "检测到旧的后端API域名: ${OLD_BACKEND_DOMAIN}。是否继续使用此域名? (y/N): " USE_OLD_BACKEND_DOMAIN
        if [[ "$USE_OLD_BACKEND_DOMAIN" == "y" || "$USE_OLD_BACKEND_DOMAIN" == "Y" ]]; then
            BACKEND_DOMAIN="$OLD_BACKEND_DOMAIN"
            echo "继续使用后端域名: $BACKEND_DOMAIN"
        else
            read -p "请输入您的后端API域名 (例如: https://monitor.yourdomain.com): " BACKEND_DOMAIN
        fi
    else
        read -p "请输入您的后端API域名 (例如: https://monitor.yourdomain.com): " BACKEND_DOMAIN
    fi

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
    echo -e "${GREEN}密码验证成功！正在继续安装/更新...${NC}"

    # 3. 安装依赖
    echo "--> 正在检查并安装/更新依赖 (sysstat, bc)..."
    dpkg -s sysstat >/dev/null 2>&1 || sudo apt-get install -y sysstat
    dpkg -s bc >/dev/null 2>&1 || sudo apt-get install -y bc
    if [ $? -ne 0 ]; then
        echo -e "${RED}错误：依赖 'sysstat' 或 'bc' 安装失败。${NC}"
        exit 1
    fi

    # 4. 获取服务器信息
    local SERVER_ID_INPUT="$OLD_SERVER_ID"
    local SERVER_NAME_INPUT="$OLD_SERVER_NAME"
    local SERVER_LOCATION_INPUT="$OLD_SERVER_LOCATION"

    if [ -z "$OLD_SERVER_ID" ]; then
        read -p "请为当前服务器设置一个唯一的ID (例如: web-server-01): " SERVER_ID_INPUT
    else
        read -p "检测到旧的服务器ID: ${OLD_SERVER_ID}。是否继续使用此ID? (y/N): " USE_OLD_SERVER_ID
        if [[ "$USE_OLD_SERVER_ID" == "y" || "$USE_OLD_SERVER_ID" == "Y" ]]; then
            echo "继续使用服务器ID: $SERVER_ID_INPUT"
        else
            read -p "请为当前服务器设置一个唯一的ID (例如: web-server-01): " SERVER_ID_INPUT
        fi
    fi

    if [ -z "$OLD_SERVER_NAME" ]; then
        read -p "请输入当前服务器的名称 (例如: 亚太-Web服务器): " SERVER_NAME_INPUT
    else
        read -p "检测到旧的服务器名称: ${OLD_SERVER_NAME}。是否继续使用此名称? (y/N): " USE_OLD_SERVER_NAME
        if [[ "$USE_OLD_SERVER_NAME" == "y" || "$USE_OLD_SERVER_NAME" == "Y" ]]; then
            echo "继续使用服务器名称: $SERVER_NAME_INPUT"
        else
            read -p "请输入当前服务器的名称 (例如: 亚太-Web服务器): " SERVER_NAME_INPUT
        fi
    fi

    if [ -z "$OLD_SERVER_LOCATION" ]; then
        read -p "请输入当前服务器的位置 (例如: 新加坡): " SERVER_LOCATION_INPUT
    else
        read -p "检测到旧的位置: ${OLD_SERVER_LOCATION}。是否继续使用此位置? (y/N): " USE_OLD_SERVER_LOCATION
        if [[ "$USE_OLD_SERVER_LOCATION" == "y" || "$USE_OLD_SERVER_LOCATION" == "Y" ]]; then
            echo "继续使用服务器位置: $SERVER_LOCATION_INPUT"
        else
            read -p "请输入当前服务器的位置 (例如: 新加坡): " SERVER_LOCATION_INPUT
        fi
    fi

    NET_INTERFACE=$(ip -o -4 route show to default | awk '{print $5}')
    echo "--> 自动检测到网络接口为: $NET_INTERFACE"

    # 5. 部署Agent脚本 (强制更新)
    echo "--> 正在部署/更新Agent脚本..."
    sudo mkdir -p /opt/monitor-agent
    sudo curl -s -L "https://raw.githubusercontent.com/cjap111/vps-monitor-panel/main/agent/agent.sh" -o /opt/monitor-agent/agent.sh
    sudo chmod +x /opt/monitor-agent/agent.sh

    # 6. 更新Agent配置
    sudo sed -i "s|BACKEND_URL=.*|BACKEND_URL=\"$BACKEND_DOMAIN/api/report\"|g" /opt/monitor-agent/agent.sh
    sudo sed -i "s|SERVER_ID=.*|SERVER_ID=\"$SERVER_ID_INPUT\"|g" /opt/monitor-agent/agent.sh
    sudo sed -i "s|SERVER_NAME=.*|SERVER_NAME=\"$SERVER_NAME_INPUT\"|g" /opt/monitor-agent/agent.sh
    sudo sed -i "s|SERVER_LOCATION=.*|SERVER_LOCATION=\"$SERVER_LOCATION_INPUT\"|g" /opt/monitor-agent/agent.sh
    sudo sed -i "s|NET_INTERFACE=.*|NET_INTERFACE=\"$NET_INTERFACE\"|g" /opt/monitor-agent/agent.sh
    
    # 7. 创建或更新Systemd服务
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
    sudo systemctl stop monitor-backend.service > /dev/null 2>&1
    sudo systemctl disable monitor-backend.service > /dev/null 2>&1
    
    # 2. 删除后端文件和服务文件
    echo "--> 正在删除后端文件..."
    sudo rm -rf /opt/monitor-backend
    sudo rm -f /etc/systemd/system/monitor-backend.service
    
    # 3. 停止Nginx
    echo "--> 正在停止Nginx..."
    sudo systemctl stop nginx > /dev/null 2>&1
    
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
    sudo systemctl stop monitor-agent.service > /dev/null 2>&1
    sudo systemctl disable monitor-agent.service > /dev/null 2>&1
    
    # 2. 删除Agent文件和服务文件
    echo "--> 正在删除Agent文件..."
    sudo rm -rf /opt/monitor-agent
    sudo rm -f /etc/systemd/system/monitor-agent.service
    
    # 3. 重载Systemd
    echo "--> 正在重载服务...约5秒后完成"
    sudo systemctl daemon-reload
    
    echo -e "${GREEN}=====================================================${NC}"
    echo -e "${GREEN}          被控端Agent卸载成功! ✅${NC}"
    echo -e "请记得到您的监控面板网页端手动删除此服务器。 "
    echo -e "${GREEN}=====================================================${NC}"
}

# --- 主菜单 ---
echo "请选择要执行的操作: (再次运行本脚本即可安装或更新)"
echo "1) 安装/更新服务端 (Frontend + Backend)"
echo "2) 安装/更新被控端 (Agent)"
echo "3) 卸载服务端"
echo "4) 卸载被控端"
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
