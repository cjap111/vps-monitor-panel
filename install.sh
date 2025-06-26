#!/bin/bash

# =================================================================
#
#          一键式服务器监控面板安装/卸载/更新脚本 v1.9
#
# =================================================================

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m' # 修正：移除了多余的反斜杠
NC='\\033[0m' # No Color - 修复了这里的反斜杠，使其能正确重置颜色

# --- 脚本欢迎信息 ---
echo -e "${GREEN}=====================================================${NC}"
echo -e "${GREEN}      欢迎使用服务器监控面板一键安装/卸载/更新脚本V1.9      ${NC}"
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

    # Set server timezone to Asia/Shanghai
    echo "--> 正在设置服务器时区为 Asia/Shanghai..."
    sudo timedatectl set-timezone Asia/Shanghai
    if [ $? -ne 0 ]; then
        echo -e "${RED}错误：设置时区失败。请手动检查并设置，或确保 timedatectl 命令可用。${NC}"
    else
        echo -e "${GREEN}服务器时区已设置为 Asia/Shanghai。${NC}"
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
    
    # 3. 部署前端 (强制更新) - Deploy frontend first as it's needed for Certbot's webroot challenge
    echo "--> 正在部署/更新前端面板..."
    sudo mkdir -p /var/www/monitor-frontend
    sudo curl -s -L "https://raw.githubusercontent.com/cjap111/vps-monitor-panel/main/frontend/index.html" -o /var/www/monitor-frontend/index.html
    # 替换前端HTML中的API_ENDPOINT，使其指向当前域名
    sudo sed -i "s|https://monitor.yourdomain.com/api|https://$DOMAIN/api|g" /var/www/monitor-frontend/index.html

    # Ensure /var/www/certbot exists for Certbot webroot challenge
    sudo mkdir -p /var/www/certbot
    sudo chown -R www-data:www-data /var/www/certbot # Ensure Nginx user can write

    # 4. Configure Nginx for Certbot HTTP challenge
    echo "--> 正在配置Nginx HTTP服务用于Certbot验证..."
    NGINX_CONF="/etc/nginx/sites-available/$DOMAIN"
    sudo tee "$NGINX_CONF" > /dev/null <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    # Certbot's well-known location for HTTP-01 challenge
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    # Redirect all other HTTP traffic to HTTPS later
    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF
    # Remove old domain's Nginx symlink if domain changed
    if [ -n "$OLD_DOMAIN_FROM_ENV" ] && [ "$OLD_DOMAIN_FROM_ENV" != "$DOMAIN" ] && [ -f "/etc/nginx/sites-enabled/$OLD_DOMAIN_FROM_ENV" ]; then
        echo "--> 检测到域名更改，正在移除旧Nginx符号链接..."
        sudo rm -f "/etc/nginx/sites-enabled/$OLD_DOMAIN_FROM_ENV"
    fi
    sudo ln -s -f "$NGINX_CONF" /etc/nginx/sites-enabled/
    echo "--> 测试Nginx配置 (HTTP Only)..."
    sudo nginx -t
    if [ $? -ne 0 ]; then
        echo -e "${RED}错误：Nginx HTTP配置测试失败。请检查您的Nginx配置。${NC}"
        exit 1
    fi
    sudo systemctl restart nginx # Restart Nginx to pick up HTTP config for Certbot

    # 5. Get SSL certificate (if not existing and valid)
    echo "--> 正在为 $DOMAIN 获取或续订SSL证书..."

    local EMAIL_TO_USE=""
    # First, determine the email to use for Certbot
    if [ -n "$OLD_EMAIL" ]; then
        read -p "检测到旧邮箱地址: ${OLD_EMAIL}。是否继续使用此邮箱? (y/N): " USE_OLD_EMAIL_PROMPT
        if [[ "$USE_OLD_EMAIL_PROMPT" == "y" || "$USE_OLD_EMAIL_PROMPT" == "Y" ]]; then
            EMAIL_TO_USE="$OLD_EMAIL"
            echo "继续使用邮箱: $EMAIL_TO_USE"
        else
            read -p "请输入您的邮箱地址 (用于Let's Encrypt证书续订提醒): " EMAIL_TO_USE_INPUT
            EMAIL_TO_USE="$EMAIL_TO_USE_INPUT"
        fi
    else
        read -p "请输入您的邮箱地址 (用于Let's Encrypt证书续订提醒): " EMAIL_TO_USE
    fi

    if [ -z "$EMAIL_TO_USE" ]; then
        echo -e "${RED}错误：邮箱地址不能为空！申请SSL证书需要提供邮箱。${NC}"
        exit 1 # Email is mandatory for new certificate application
    fi
    EMAIL="$EMAIL_TO_USE" # Set global EMAIL for the script to use

    # Attempt account registration.
    echo "--> 尝试注册Certbot账户 (如果尚未注册)..."
    # Capture output and exit code of certbot register command
    REGISTER_OUTPUT=$(sudo certbot register --email "$EMAIL" --agree-tos --non-interactive --no-eff-email 2>&1)
    REGISTER_STATUS=$?

    if [ $REGISTER_STATUS -eq 0 ]; then
        echo -e "${GREEN}Certbot账户注册/更新成功！${NC}"
    elif echo "$REGISTER_OUTPUT" | grep -q "There is an existing account"; then
        # Handle the case where the account already exists, which is not an error for our purpose.
        echo -e "${GREEN}Certbot账户已存在，继续。${NC}"
    else
        echo -e "${RED}错误：Certbot账户注册失败。${NC}"
        echo -e "${RED}详细错误信息：${REGISTER_OUTPUT}${NC}"
        echo -e "如果问题持续存在，请访问Let's Encrypt社区获取帮助。"
        exit 1
    fi

    # Now, attempt to obtain or renew the certificate, or skip if valid one already exists
    # Check if certificate already exists and is VALID for the domain
    if sudo certbot certificates -d "$DOMAIN" | grep -q "VALID"; then
        echo -e "${GREEN}检测到现有有效的SSL证书已绑定到 ${DOMAIN}，跳过新证书申请。Certbot会自动处理续订。${NC}"
    else
        echo "--> 运行Certbot获取证书..."
        if ! sudo certbot --nginx --agree-tos --non-interactive -m "$EMAIL" -d "$DOMAIN"; then
            echo -e "${RED}错误：Certbot未能成功获取或更新SSL证书。请检查您的域名解析（A/AAAA记录）和网络连接。${NC}"
            echo -e "您可以在手动运行 'sudo certbot --nginx -d $DOMAIN' 来尝试诊断问题。"
            exit 1
        fi
        echo -e "${GREEN}Certbot证书获取/更新成功！${NC}"
    fi

    # 6. Now, configure Nginx for full HTTPS with the obtained certificates
    echo "--> 正在配置Nginx HTTPS服务..."
    sudo tee "$NGINX_CONF" > /dev/null <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri; # Force HTTP to HTTPS redirection
}

server {
    listen 443 ssl http2; # Enable HTTP/2
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    ssl_stapling on;
    ssl_stapling_verify on;
    resolver 8.8.8.8 8.8.4.4 valid=300s;
    resolver_timeout 5s;

    root /var/www/monitor-frontend; # Frontend files root directory
    index index.html; # Default index file

    location /api {
        proxy_pass http://127.0.0.1:3000; # Proxy /api requests to Node.js backend
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
        proxy_connect_timeout 600;
        proxy_send_timeout 600;
        proxy_read_timeout 600;
    }

    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
EOF
    echo "--> 测试Nginx配置 (HTTPS Enabled)..."
    sudo nginx -t
    if [ $? -ne 0 ]; then
        echo -e "${RED}错误：Nginx HTTPS配置测试失败。请检查配置。${NC}"
        exit 1
    fi
    sudo systemctl restart nginx # Final restart to pick up HTTPS config
    
    # 7. Deploy Backend (forced update)
    echo "--> 正在部署/更新后端API服务..."
    sudo mkdir -p /opt/monitor-backend
    cd /opt/monitor-backend
    sudo curl -s -L "https://raw.githubusercontent.com/cjap111/vps-monitor-panel/main/backend/server.js" -o server.js
    sudo curl -s -L "https://raw.githubusercontent.com/cjap111/vps-monitor-panel/main/backend/package.json" -o package.json
    echo "--> 正在安装/更新后端依赖..."
    sudo npm install

    # IMPORTANT NOTE: The 'server_data.json' file, which stores accumulated traffic data,
    # is NOT deleted during a normal 'install_server' (update) operation.
    # It will persist across updates. However, running 'uninstall_server' WILL delete it.
    # If you wish to manually backup your data, copy /opt/monitor-backend/server_data.json before uninstallation.

    # 8. Create or update environment file
    echo "--> 正在配置/更新后端环境变量..."
    sudo tee "$BACKEND_ENV_FILE" > /dev/null <<EOF
DELETE_PASSWORD=$DEL_PASSWORD
AGENT_INSTALL_PASSWORD=$AGENT_PASSWORD
DOMAIN=$DOMAIN # Explicitly save domain to .env file
${EMAIL:+CERTBOT_EMAIL=$EMAIL} # If email is set, save to .env
EOF

    # 9. Create or update Systemd service
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
    echo -e "请牢记您设置的两种密码！"
    echo -e "现在您可以去需要监控的服务器上，运行此脚本并选择'安装被控端'来进行安装或更新。"
    echo -e "${GREEN}=====================================================${NC}"
}

# --- Function: Install/Update Agent ---
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
        # Stop service to avoid conflicts
        echo "--> 正在停止现有Agent服务..."
        sudo systemctl stop monitor-agent.service > /dev/null 2>&1
        sudo systemctl disable monitor-agent.service > /dev/null 2>&1
        
        # Try to read configuration from old script, suppress grep errors
        OLD_BACKEND_URL=$(grep "BACKEND_URL=" "$AGENT_PATH" 2>/dev/null | cut -d\" -f2)
        OLD_SERVER_ID=$(grep "SERVER_ID=" "$AGENT_PATH" 2>/dev/null | cut -d\" -f2)
        OLD_SERVER_NAME=$(grep "SERVER_NAME=" "$AGENT_PATH" 2>/dev/null | cut -d\" -f2)
        OLD_SERVER_LOCATION=$(grep "SERVER_LOCATION=" "$AGENT_PATH" 2>/dev/null | cut -d\" -f2)
        OLD_NET_INTERFACE=$(grep "NET_INTERFACE=" "$AGENT_PATH" 2>/dev/null | cut -d\" -f2)

        # Extract domain from full URL
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

    # 1. Get user input
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
    
    # 2. Verify password
    echo "--> 正在验证安装密码..."
    VERIFY_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" -d "{\"password\":\"$AGENT_INSTALL_PASSWORD_INPUT\"}" "$BACKEND_DOMAIN/api/verify-agent-password")
    
    if [ "$VERIFY_STATUS" -ne 200 ]; then
        echo -e "${RED}错误：被控端安装密码错误或无法连接到后端！状态码: $VERIFY_STATUS${NC}"
        exit 1
    fi
    echo -e "${GREEN}密码验证成功！正在继续安装/更新...${NC}"

    # 3. Install dependencies
    echo "--> 正在检查并安装/更新依赖 (sysstat, bc)..."
    dpkg -s sysstat >/dev/null 2>&1 || sudo apt-get install -y sysstat
    dpkg -s bc >/dev/null 2>&1 || sudo apt-get install -y bc
    if [ $? -ne 0 ]; then
        echo -e "${RED}错误：依赖 'sysstat' 或 'bc' 安装失败。${NC}"
        exit 1
    fi

    # 4. Get server information
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

    # 5. Deploy Agent Script (forced update)
    echo "--> 正在部署/更新Agent脚本..."
    sudo mkdir -p /opt/monitor-agent
    sudo curl -s -L "https://raw.githubusercontent.com/cjap111/vps-monitor-panel/main/agent/agent.sh" -o /opt/monitor-agent/agent.sh
    sudo chmod +x /opt/monitor-agent/agent.sh

    # 6. Update Agent Configuration
    sudo sed -i "s|BACKEND_URL=.*|BACKEND_URL=\"$BACKEND_DOMAIN/api/report\"|g" /opt/monitor-agent/agent.sh
    sudo sed -i "s|SERVER_ID=.*|SERVER_ID=\"$SERVER_ID_INPUT\"|g" /opt/monitor-agent/agent.sh
    sudo sed -i "s|SERVER_NAME=.*|SERVER_NAME=\"$SERVER_NAME_INPUT\"|g" /opt/monitor-agent/agent.sh
    sudo sed -i "s|SERVER_LOCATION=.*|SERVER_LOCATION=\"$SERVER_LOCATION_INPUT\"|g" /opt/monitor-agent/agent.sh
    sudo sed -i "s|NET_INTERFACE=.*|NET_INTERFACE=\"$NET_INTERFACE\"|g" /opt/monitor-agent/agent.sh
    
    # 7. Create or update Systemd service
    echo "--> 正在创建/更新后台上报服务..."
    sudo tee /etc/systemd/system/monitor-agent.service > /dev/null <<EOF
[Unit]
Description=Monitor Agent
Aft
