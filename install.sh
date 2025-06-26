#!/bin/bash

# =================================================================
#
#          一键式服务器监控面板安装/卸载/更新脚本 v1.9
#          修复了重新安装清除流量数据的问题和EOF错误
#
# =================================================================

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

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
    dpkg -s nodejs >/dev/null 2>&1 || sudo apt-get install -y nodejs
    dpkg -s npm >/dev/null 2>&1 || sudo apt-get install -y npm
    dpkg -s certbot >/dev/null 2>&1 || sudo apt-get install -y certbot python3-certbot-nginx

    # 检查Node.js版本，建议至少使用 Node.js 16
    NODE_VERSION=$(node -v | cut -d 'v' -f 2 | cut -d '.' -f 1)
    if (( NODE_VERSION < 16 )); then
        echo -e "${YELLOW}警告: 检测到 Node.js 版本为 v${NODE_VERSION}。建议升级到 v16 或更高版本以获得最佳兼容性。${NC}"
        echo -e "${YELLOW}您可以通过 NVM (Node Version Manager) 来管理 Node.js 版本。${NC}"
    fi

    # 2. 获取前端/后端代码
    echo "--> 正在下载或更新前端和后端代码..."
    TEMP_DIR="/tmp/monitor_panel_install"
    REPO_URL="https://github.com/cjap111/vps-monitor-panel"

    if [ -d "$TEMP_DIR" ]; then
        echo "    - 临时目录已存在，尝试更新..."
        sudo rm -rf "$TEMP_DIR" # 清理旧的临时目录
    fi
    mkdir -p "$TEMP_DIR"
    git clone --depth 1 "$REPO_URL" "$TEMP_DIR"
    if [ $? -ne 0 ]; then
        echo -e "${RED}错误：无法克隆或更新代码仓库。请检查您的网络连接或 Git 安装。${NC}"
        exit 1
    fi

    # 3. 配置 Nginx
    echo "--> 正在配置 Nginx..."
    read -p "请输入您的域名 (例如: monitor.yourdomain.com): " DOMAIN_INPUT
    FRONTEND_DIR="/var/www/monitor-frontend"
    BACKEND_PORT="3000" # 后端默认端口

    # 创建前端目录
    sudo mkdir -p "$FRONTEND_DIR"

    # Nginx 配置文件路径
    NGINX_CONF="/etc/nginx/sites-available/$DOMAIN_INPUT"
    NGINX_LINK="/etc/nginx/sites-enabled/$DOMAIN_INPUT"

    # 生成 Nginx 配置文件内容
    # 注意：这里使用了一个 heredoc，EOF 必须独占一行且没有空格
    sudo bash -c "cat > $NGINX_CONF << 'EOF'
server {
    listen 80;
    server_name $DOMAIN_INPUT;

    location / {
        root $FRONTEND_DIR;
        index index.html;
        try_files \$uri \$uri/ /index.html;
    }

    location /api {
        proxy_pass http://127.0.0.1:$BACKEND_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    # 增加 WebSocket 支持 (如果后端需要)
    location /ws {
        proxy_pass http://127.0.0.1:$BACKEND_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }
}
EOF"
    
    # 启用 Nginx 配置
    sudo ln -sf "$NGINX_CONF" "$NGINX_LINK"
    sudo nginx -t && sudo systemctl reload nginx
    if [ $? -ne 0 ]; then
        echo -e "${RED}错误：Nginx 配置测试失败或重载失败。请检查 Nginx 配置。${NC}"
        exit 1
    fi
    echo "    - Nginx 配置完成。"

    # 4. 配置 SSL (Certbot)
    echo "--> 正在配置 SSL 证书 (Certbot)..."
    read -p "是否为您的域名配置SSL证书？(y/N): " INSTALL_SSL
    if [[ "$INSTALL_SSL" == "y" || "$INSTALL_SSL" == "Y" ]]; then
        sudo certbot --nginx --non-interactive --agree-tos --email admin@$DOMAIN_INPUT -d $DOMAIN_INPUT
        if [ $? -ne 0 ]; then
            echo -e "${YELLOW}警告：Certbot 证书配置失败。您可能需要手动配置。${NC}"
        else
            echo "    - SSL 证书配置成功。"
        fi
    else
        echo "    - 跳过 SSL 证书配置。"
    fi

    # 5. 部署前端
    echo "--> 正在部署前端..."
    sudo rm -rf "$FRONTEND_DIR/*" # 清理旧的前端文件
    sudo cp -r "$TEMP_DIR/frontend/"* "$FRONTEND_DIR"
    echo "    - 前端部署完成。"

    # 更新前端 API_ENDPOINT
    sudo sed -i "s|const API_ENDPOINT = '.*'|const API_ENDPOINT = 'https://$DOMAIN_INPUT/api'|g" "$FRONTEND_DIR/index.html"
    echo "    - 前端 API_ENDPOINT 更新为 https://$DOMAIN_INPUT/api"

    # 6. 部署后端
    echo "--> 正在部署后端..."
    BACKEND_DIR="/opt/monitor-backend"
    sudo mkdir -p "$BACKEND_DIR"

    # *** 关键修改：避免删除 server_data.json ***
    # 仅删除后端代码文件，保留数据文件 server_data.json
    sudo find "$BACKEND_DIR/" -maxdepth 1 -mindepth 1 ! -name 'server_data.json' -exec rm -rf {} +

    sudo cp -r "$TEMP_DIR/backend/"* "$BACKEND_DIR"
    # 如果 backend 目录没有 server.js 和 package.json，则单独复制
    sudo cp "$TEMP_DIR/server.js" "$BACKEND_DIR/server.js"
    sudo cp "$TEMP_DIR/package.json" "$BACKEND_DIR/package.json"
    
    echo "    - 后端文件复制完成。"

    echo "--> 正在安装后端依赖..."
    (cd "$BACKEND_DIR" && sudo npm install)
    if [ $? -ne 0 ]; then
        echo -e "${RED}错误：后端依赖安装失败。请检查 npm 或网络连接。${NC}"
        exit 1
    fi
    echo "    - 后端依赖安装完成。"

    # 7. 配置后端环境变量
    echo "--> 正在配置后端环境变量..."
    read -p "请输入删除服务器的密码 (DELETE_PASSWORD): " DELETE_PASSWORD_INPUT
    read -p "请输入Agent安装密码 (AGENT_INSTALL_PASSWORD): " AGENT_INSTALL_PASSWORD_INPUT

    # 注意：这里使用了一个 heredoc，EOF 必须独占一行且没有空格
    sudo bash -c "cat > $BACKEND_DIR/.env << 'EOF'
DELETE_PASSWORD=$DELETE_PASSWORD_INPUT
AGENT_INSTALL_PASSWORD=$AGENT_INSTALL_PASSWORD_INPUT
EOF"
    echo "    - 后端环境变量配置完成。"

    # 8. 创建和启动后端服务 (systemd)
    echo "--> 正在创建 systemd 服务并启动后端..."
    # 注意：这里使用了一个 heredoc，EOF 必须独占一行且没有空格
    sudo bash -c "cat > /etc/systemd/system/monitor-backend.service << 'EOF'
[Unit]
Description=Monitor Backend Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$BACKEND_DIR
ExecStart=/usr/bin/node server.js
Restart=always
RestartSec=10
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=monitor-backend

[Install]
WantedBy=multi-user.target
EOF"
    
    sudo systemctl daemon-reload
    sudo systemctl enable monitor-backend
    sudo systemctl restart monitor-backend
    if [ $? -ne 0 ]; then
        echo -e "${RED}错误：后端服务启动失败。请检查日志 ('sudo journalctl -u monitor-backend')。${NC}"
        exit 1
    fi
    echo "    - 后端服务已启动并设置为开机自启。"

    echo -e "${GREEN}=====================================================${NC}"
    echo -e "${GREEN}      服务端 (前端 + 后端) 安装/更新成功！            ${NC}"
    echo -e "${GREEN}      请访问 http://$DOMAIN_INPUT 查看监控面板。       ${NC}"
    echo -e "${GREEN}=====================================================${NC}"
}

# --- 函数：安装/更新 Agent (客户端) ---
install_agent() {
    echo -e "${YELLOW}开始安装或更新 Agent (客户端)...${NC}"

    # 1. 获取Agent安装密码
    read -p "请输入Agent安装密码 (与服务端配置一致): " AGENT_INSTALL_PASSWORD_INPUT_AGENT
    BACKEND_DOMAIN="" # 用于Agent的后端域名

    # 检查是否存在已安装的服务端，尝试从Nginx配置中提取域名
    if [ -f "/etc/nginx/sites-available/$DOMAIN_INPUT" ]; then
        BACKEND_DOMAIN=$(grep "server_name" "/etc/nginx/sites-available/$DOMAIN_INPUT" | awk '{print $2}' | cut -d';' -f1)
        if [ -z "$BACKEND_DOMAIN" ]; then
             read -p "无法从Nginx配置中自动获取域名，请输入后端域名 (例如: monitor.yourdomain.com): " BACKEND_DOMAIN
        else
            echo "--> 自动检测到后端域名为: $BACKEND_DOMAIN"
        fi
    else
        read -p "请输入后端域名 (例如: monitor.yourdomain.com): " BACKEND_DOMAIN
    fi


    # 验证Agent安装密码
    echo "--> 正在验证Agent安装密码..."
    RESPONSE=$(curl -s -X POST -H "Content-Type: application/json" -d "{\"password\": \"$AGENT_INSTALL_PASSWORD_INPUT_AGENT\"}" "https://$BACKEND_DOMAIN/api/verify-agent-password")
    
    if echo "$RESPONSE" | grep -q "\"success\":true"; then
        echo -e "${GREEN}密码验证成功！${NC}"
    else
        echo -e "${RED}密码验证失败。请检查 Agent 安装密码是否正确。${NC}"
        echo "错误信息: $RESPONSE"
        exit 1
    fi

    # 2. 获取服务器信息
    SERVER_ID_INPUT=$(uuidgen || head /dev/urandom | tr -dc A-Za-z0-9 | head -c 16) # 生成唯一ID
    OLD_SERVER_ID=$(grep "SERVER_ID=" /opt/monitor-agent/agent.sh 2>/dev/null | cut -d'=' -f2 | tr -d '"')

    # 如果是更新，则尝试保留旧的SERVER_ID
    if [ -n "$OLD_SERVER_ID" ]; then
        read -p "检测到旧的服务器ID: ${OLD_SERVER_ID}。是否继续使用此ID? (y/N): " USE_OLD_ID
        if [[ "$USE_OLD_ID" == "y" || "$USE_OLD_ID" == "Y" ]]; then
            SERVER_ID_INPUT="$OLD_SERVER_ID"
            echo "继续使用服务器ID: $SERVER_ID_INPUT"
        else
            read -p "请输入当前服务器的唯一ID (例如: my-server-001): " SERVER_ID_INPUT
        fi
    else
        read -p "请输入当前服务器的唯一ID (例如: my-server-001，将作为服务器的唯一标识): " SERVER_ID_INPUT
    fi

    OLD_SERVER_NAME=$(grep "SERVER_NAME=" /opt/monitor-agent/agent.sh 2>/dev/null | cut -d'=' -f2 | tr -d '"')
    if [ -n "$OLD_SERVER_NAME" ]; then
        read -p "检测到旧的服务器名称: ${OLD_SERVER_NAME}。是否继续使用此名称? (y/N): " USE_OLD_SERVER_NAME
        if [[ "$USE_OLD_SERVER_NAME" == "y" || "$USE_OLD_SERVER_NAME" == "Y" ]]; then
            SERVER_NAME_INPUT="$OLD_SERVER_NAME"
            echo "继续使用服务器名称: $SERVER_NAME_INPUT"
        else
            read -p "请输入当前服务器的名称 (例如: 我的Debian服务器): " SERVER_NAME_INPUT
        fi
    else
        read -p "请输入当前服务器的名称 (例如: 我的Debian服务器): " SERVER_NAME_INPUT
    fi

    OLD_SERVER_LOCATION=$(grep "SERVER_LOCATION=" /opt/monitor-agent/agent.sh 2>/dev/null | cut -d'=' -f2 | tr -d '"')
    if [ -n "$OLD_SERVER_LOCATION" ]; then
        read -p "检测到旧的位置: ${OLD_SERVER_LOCATION}。是否继续使用此位置? (y/N): " USE_OLD_SERVER_LOCATION
        if [[ "$USE_OLD_SERVER_LOCATION" == "y" || "$USE_OLD_SERVER_LOCATION" == "Y" ]]; then
            SERVER_LOCATION_INPUT="$OLD_SERVER_LOCATION"
            echo "继续使用服务器位置: $SERVER_LOCATION_INPUT"
        else
            read -p "请输入当前服务器的位置 (例如: 新加坡): " SERVER_LOCATION_INPUT
        fi
    else
        read -p "请输入当前服务器的位置 (例如: 新加坡): " SERVER_LOCATION_INPUT
    fi

    NET_INTERFACE=$(ip -o -4 route show to default | awk '{print $5}')
    echo "--> 自动检测到网络接口为: $NET_INTERFACE"

    # 3. 部署 Agent Script (forced update)
    echo "--> 正在部署/更新Agent脚本..."
    sudo mkdir -p /opt/monitor-agent
    sudo curl -s -L "https://raw.githubusercontent.com/cjap111/vps-monitor-panel/main/agent/agent.sh" -o /opt/monitor-agent/agent.sh
    sudo chmod +x /opt/monitor-agent/agent.sh

    # 4. 更新 Agent Configuration
    sudo sed -i "s|BACKEND_URL=.*|BACKEND_URL=\"https://$BACKEND_DOMAIN/api/report\"|g" /opt/monitor-agent/agent.sh
    sudo sed -i "s|SERVER_ID=.*|SERVER_ID=\"$SERVER_ID_INPUT\"|g" /opt/monitor-agent/agent.sh
    sudo sed -i "s|SERVER_NAME=.*|SERVER_NAME=\"$SERVER_NAME_INPUT\"|g" /opt/monitor-agent/agent.sh
    sudo sed -i "s|SERVER_LOCATION=.*|SERVER_LOCATION=\"$SERVER_LOCATION_INPUT\"|g" /opt/monitor-agent/agent.sh
    sudo sed -i "s|NET_INTERFACE=.*|NET_INTERFACE=\"$NET_INTERFACE\"|g" /opt/monitor-agent/agent.sh
    echo "    - Agent 配置更新完成。"

    # 5. 创建和启动 Agent 服务 (systemd)
    echo "--> 正在创建 systemd 服务并启动 Agent..."
    # 注意：这里使用了一个 heredoc，EOF 必须独占一行且没有空格
    sudo bash -c "cat > /etc/systemd/system/monitor-agent.service << 'EOF'
[Unit]
Description=Monitor Agent Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/monitor-agent
ExecStart=/bin/bash /opt/monitor-agent/agent.sh
Restart=always
RestartSec=60
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=monitor-agent

[Install]
WantedBy=multi-user.target
EOF"
    
    sudo systemctl daemon-reload
    sudo systemctl enable monitor-agent
    sudo systemctl restart monitor-agent
    if [ $? -ne 0 ]; then
        echo -e "${RED}错误：Agent 服务启动失败。请检查日志 ('sudo journalctl -u monitor-agent')。${NC}"
        exit 1
    fi
    echo "    - Agent 服务已启动并设置为开机自启。"

    echo -e "${GREEN}=====================================================${NC}"
    echo -e "${GREEN}          Agent (客户端) 安装/更新成功！            ${NC}"
    echo -e "${GREEN}=====================================================${NC}"
}

# --- 函数：卸载服务端 ---
uninstall_server() {
    echo -e "${YELLOW}开始卸载服务端 (前端 + 后端)...${NC}"
    
    # 获取域名以便清理 Nginx 配置
    read -p "请输入您安装时使用的域名 (例如: monitor.yourdomain.com): " DOMAIN_TO_UNINSTALL

    echo "--> 正在停止并删除后端服务..."
    sudo systemctl stop monitor-backend
    sudo systemctl disable monitor-backend
    sudo rm -f /etc/systemd/system/monitor-backend.service
    sudo rm -rf /opt/monitor-backend # 彻底删除后端文件和数据

    echo "--> 正在清理 Nginx 配置和前端文件..."
    sudo rm -f "/etc/nginx/sites-available/$DOMAIN_TO_UNINSTALL"
    sudo rm -f "/etc/nginx/sites-enabled/$DOMAIN_TO_UNINSTALL"
    sudo rm -rf "/var/www/monitor-frontend"

    # 尝试重载 Nginx
    sudo nginx -t && sudo systemctl reload nginx 2>/dev/null
    
    echo -e "${GREEN}服务端卸载完成！${NC}"
    echo -e "${GREEN}请手动删除 Certbot 证书 (如果已安装): sudo certbot delete --cert-name $DOMAIN_TO_UNINSTALL ${NC}"
}

# --- 函数：卸载 Agent ---
uninstall_agent() {
    echo -e "${YELLOW}开始卸载 Agent (客户端)...${NC}"
    echo "--> 正在停止并删除 Agent 服务..."
    sudo systemctl stop monitor-agent
    sudo systemctl disable monitor-agent
    sudo rm -f /etc/systemd/system/monitor-agent.service
    sudo rm -rf /opt/monitor-agent # 彻底删除 Agent 文件

    echo -e "${GREEN}Agent 卸载完成！${NC}"
}

# --- 主菜单 ---
while true; do
    echo -e "${GREEN}请选择您要执行的操作:${NC}"
    echo "1. ${GREEN}安装或更新服务端 (前端 + 后端)${NC}"
    echo "2. ${GREEN}安装或更新 Agent (客户端)${NC}"
    echo "3. ${RED}卸载服务端 (前端 + 后端)${NC}"
    echo "4. ${RED}卸载 Agent (客户端)${NC}"
    echo "5. ${YELLOW}退出${NC}"
    echo -n "请输入您的选择 [1-5]: "
    read CHOICE

    case $CHOICE in
        1)
            install_server
            break
            ;;
        2)
            install_agent
            break
            ;;
        3)
            uninstall_server
            break
            ;;
        4)
            uninstall_agent
            break
            ;;
        5)
            echo "退出脚本。"
            break
            ;;
        *)
            echo -e "${RED}无效的选择，请输入 1 到 5 之间的数字。${NC}"
            ;;
    esac
    echo ""
done
