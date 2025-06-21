#!/bin/bash -e

# =================================================================
#
#       一键式服务器监控面板安装/卸载脚本 v2.1 (最终稳定版)
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
    
    # 1. 更新并安装依赖
    echo "--> 正在更新软件包列表..."
    sudo apt-get update
    echo "--> 正在安装依赖 (Nginx, Node.js, Certbot)..."
    sudo apt-get install -y nginx nodejs npm certbot python3-certbot-nginx
    if [ $? -ne 0 ]; then
        echo -e "${RED}错误：依赖安装失败。请检查上面的错误信息。${NC}"
        exit 1
    fi

    # 2. 获取用户输入
    read -p "请输入您解析到本服务器的域名 (例如: monitor.yourdomain.com): " DOMAIN
    if [ -z "$DOMAIN" ]; then echo -e "${RED}错误：域名不能为空！${NC}"; exit 1; fi
    
    read -s -p "请为【网页端删除功能】设置一个强密码: " DEL_PASSWORD; echo
    read -s -p "请为【被控端安装功能】设置一个强密码: " AGENT_PASSWORD; echo
    if [ -z "$DEL_PASSWORD" ] || [ -z "$AGENT_PASSWORD" ]; then echo -e "${RED}错误：密码不能为空！${NC}"; exit 1; fi
    
    # 3. 配置Nginx
    echo "--> 正在配置Nginx反向代理..."
    sudo tee "/etc/nginx/sites-available/$DOMAIN" > /dev/null <<'EOF'
server {
    listen 80;
    server_name YOUR_DOMAIN;
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
    sudo sed -i "s/YOUR_DOMAIN/$DOMAIN/g" "/etc/nginx/sites-available/$DOMAIN"
    sudo ln -s -f "/etc/nginx/sites-available/$DOMAIN" /etc/nginx/sites-enabled/
    sudo nginx -t

    # 4. 获取SSL证书
    echo "--> 正在为 $DOMAIN 获取SSL证书..."
    read -p "请输入您的邮箱地址 (用于Let's Encrypt证书续订提醒): " EMAIL
    sudo certbot --nginx --agree-tos --redirect --non-interactive -m "$EMAIL" -d "$DOMAIN"

    # 5. 部署前端 (内置文件)
    echo "--> 正在部署前端面板..."
    sudo mkdir -p /var/www/monitor-frontend
    sudo tee /var/www/monitor-frontend/index.html > /dev/null <<'EOF'
<!DOCTYPE html><html lang="zh-CN"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>Ubuntu风格服务器监控面板</title><script src="https://cdn.tailwindcss.com"></script><link rel="preconnect" href="https://fonts.googleapis.com"><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin><link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap" rel="stylesheet"><script src="https://unpkg.com/lucide@latest"></script><style>body{font-family:'Inter',sans-serif;background-color:#1a1a1a}.status-dot{width:10px;height:10px;border-radius:50%;display:inline-block;margin-right:8px}.status-online{background-color:#2ecc71;box-shadow:0 0 8px #2ecc71}.status-offline{background-color:#e74c3c;box-shadow:0 0 8px #e74c3c}.card{background-color:#2c2c2c;border:1px solid #3d3d3d;transition:transform .3s ease,box-shadow .3s ease;position:relative;overflow:hidden}.card:hover{transform:translateY(-5px);box-shadow:0 10px 20px rgba(0,0,0,.4)}.progress-bar-bg{background-color:#444}.progress-bar{transition:width .5s ease-in-out}::-webkit-scrollbar{width:8px}::-webkit-scrollbar-track{background:#2c2c2c}::-webkit-scrollbar-thumb{background:#555;border-radius:4px}::-webkit-scrollbar-thumb:hover{background:#777}.modal-backdrop{background-color:rgba(0,0,0,.7);backdrop-filter:blur(4px)}.icon-btn{background:rgba(255,255,255,.1);border-radius:50%;padding:4px;transition:background .2s}.icon-btn:hover{background:rgba(255,255,255,.2)}</style></head><body class="text-gray-200"><div class="container mx-auto p-4 md:p-8"><header class="flex justify-between items-center mb-8"><div class="flex items-center space-x-3"><svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="text-orange-500"><path d="M12 1a11 11 0 1 0 0 22 11 11 0 0 0 0-22V1z"/><path d="M12 5a7 7 0 1 0 0 14 7 7 0 0 0 0-14z"/><path d="M12 9a3 3 0 1 0 0 6 3 3 0 0 0 0-6z"/></svg><h1 class="text-2xl md:text-3xl font-bold text-white">服务器状态监控面板</h1><span class="text-sm text-gray-400 mt-1">Ubuntu-Style</span></div><button id="addServerBtn" class="bg-indigo-600 hover:bg-indigo-700 text-white font-bold py-2 px-4 rounded-lg flex items-center space-x-2 transition-transform duration-200 transform hover:scale-105"><i data-lucide="plus-circle" class="w-5 h-5"></i><span>添加服务器</span></button></header><main id="server-grid" class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-6"></main></div><template id="server-card-template"><div class="card rounded-lg p-5 flex flex-col space-y-4"><div class="flex justify-between items-start"><div><h2 class="text-lg font-bold text-white truncate" data-id="name">服务器名称</h2><div class="text-xs text-gray-400 flex items-center space-x-2 mt-1"><i data-lucide="ubuntu" class="w-4 h-4"></i><span data-id="os">Ubuntu 22.04 LTS</span></div></div><div class="flex items-center space-x-2"><div class="flex items-center"><span class="status-dot" data-id="status-dot"></span><span class="font-medium text-sm" data-id="status-text"></span></div><button class="icon-btn text-gray-300" data-action="settings"><i data-lucide="settings-2" class="w-5 h-5"></i></button><button class="icon-btn text-red-500" data-action="delete"><i data-lucide="trash-2" class="w-5 h-5"></i></button></div></div><div class="space-y-4 pt-2"><div class="resource-item"><div class="flex justify-between text-sm mb-1"><span>CPU</span><span class="font-mono" data-id="cpu-usage">0%</span></div><div class="w-full progress-bar-bg rounded-full h-2.5"><div class="bg-blue-500 h-2.5 rounded-full progress-bar" data-id="cpu-bar" style="width:0%"></div></div></div><div class="resource-item"><div class="flex justify-between text-sm mb-1"><span>内存</span><span class="font-mono text-xs" data-id="mem-usage">0 MB / 0 MB</span></div><div class="w-full progress-bar-bg rounded-full h-2.5"><div class="bg-purple-500 h-2.5 rounded-full progress-bar" data-id="mem-bar" style="width:0%"></div></div></div><div class="resource-item"><div class="flex justify-between text-sm mb-1"><span>硬盘</span><span class="font-mono text-xs" data-id="disk-usage">0 GB / 0 GB</span></div><div class="w-full progress-bar-bg rounded-full h-2.5"><div class="bg-green-500 h-2.5 rounded-full progress-bar" data-id="disk-bar" style="width:0%"></div></div></div></div><div class="pt-4 border-t border-gray-700/50 flex flex-col space-y-2"><div class="flex justify-between text-sm text-gray-300"><div class="flex items-center space-x-2"><i data-lucide="arrow-down-circle" class="w-4 h-4 text-cyan-400"></i><span class="font-mono" data-id="net-down">0 KB/s</span></div><div class="flex items-center space-x-2"><i data-lucide="arrow-up-circle" class="w-4 h-4 text-red-400"></i><span class="font-mono" data-id="net-up">0 KB/s</span></div></div><div class="text-xs text-gray-500 flex items-center space-x-2"><i data-lucide="clock" class="w-4 h-4"></i><span data-id="uptime">在线 0 天</span></div></div><div class="pt-3 mt-3 border-t border-gray-700/50 text-xs text-gray-400 space-y-1"><div class="flex justify-between items-center"><span class="flex items-center space-x-2 font-medium"><i data-lucide="bar-chart-3" class="w-4 h-4"></i><span>总流量</span></span><span class="text-gray-500" data-id="reset-info">每月1日重置</span></div><div class="flex justify-between items-center pl-1"><span class="flex items-center space-x-1.5 text-red-400"><i data-lucide="arrow-up" class="w-3 h-3"></i><span data-id="total-net-up" class="font-mono">0 GB</span></span><span class="flex items-center space-x-1.5 text-cyan-400"><i data-lucide="arrow-down" class="w-3 h-3"></i><span data-id="total-net-down" class="font-mono">0 GB</span></span></div></div></div></template><div id="addServerModal" class="fixed inset-0 z-50 items-center justify-center hidden modal-backdrop"><div class="bg-[#2c2c2c] rounded-lg shadow-xl p-8 w-full max-w-md m-4 border border-gray-700"><div class="flex justify-between items-center mb-6"><h3 class="text-xl font-bold text-white">添加新的服务器</h3><button data-action="close" class="text-gray-400 hover:text-white"><i data-lucide="x" class="w-6 h-6"></i></button></div><form id="addServerForm"><div class="text-center p-4 rounded-lg bg-gray-700/50 border border-gray-600"><p class="text-gray-300">请在需要监控的服务器上运行此脚本，并选择“安装被控端”来添加服务器。</p></div><div class="flex justify-end mt-6"><button type="button" data-action="close" class="bg-indigo-600 hover:bg-indigo-700 text-white font-bold py-2 px-4 rounded-lg">好的</button></div></form></div></div><div id="serverSettingsModal" class="fixed inset-0 z-50 items-center justify-center hidden modal-backdrop"><div class="bg-[#2c2c2c] rounded-lg shadow-xl p-8 w-full max-w-md m-4 border border-gray-700"><div class="flex justify-between items-center mb-6"><h3 class="text-xl font-bold text-white">服务器设置</h3><button data-action="close" class="text-gray-400 hover:text-white"><i data-lucide="x" class="w-6 h-6"></i></button></div><form id="serverSettingsForm"><input type="hidden" id="settingServerId"><div class="space-y-4"><div><label for="manualTotalUp" class="block text-sm font-medium text-gray-300 mb-2">手动设置总上传量 (GB)</label><input type="number" step="0.01" id="manualTotalUp" class="w-full bg-gray-700 border border-gray-600 rounded-lg px-3 py-2 text-white focus:ring-indigo-500 focus:border-indigo-500" required></div><div><label for="manualTotalDown" class="block text-sm font-medium text-gray-300 mb-2">手动设置总下载量 (GB)</label><input type="number" step="0.01" id="manualTotalDown" class="w-full bg-gray-700 border border-gray-600 rounded-lg px-3 py-2 text-white focus:ring-indigo-500 focus:border-indigo-500" required></div><div><label for="resetDay" class="block text-sm font-medium text-gray-300 mb-2">每月重置日期 (1-31)</label><input type="number" min="1" max="31" id="resetDay" class="w-full bg-gray-700 border border-gray-600 rounded-lg px-3 py-2 text-white focus:ring-indigo-500 focus:border-indigo-500" required></div></div><div class="flex justify-end space-x-4 mt-8"><button type="button" data-action="close" class="bg-gray-600 hover:bg-gray-700 text-white font-bold py-2 px-4 rounded-lg">取消</button><button type="submit" class="bg-indigo-600 hover:bg-indigo-700 text-white font-bold py-2 px-4 rounded-lg">保存设置</button></div></form></div></div><div id="deleteServerModal" class="fixed inset-0 z-50 items-center justify-center hidden modal-backdrop"><div class="bg-[#2c2c2c] rounded-lg shadow-xl p-8 w-full max-w-md m-4 border border-red-500/50"><div class="flex justify-between items-center mb-4"><h3 class="text-xl font-bold text-red-500">确认删除</h3><button data-action="close" class="text-gray-400 hover:text-white"><i data-lucide="x" class="w-6 h-6"></i></button></div><p class="text-gray-300 mb-6">您确定要删除服务器 <strong id="deleteServerName" class="text-yellow-400"></strong> 吗？此操作不可逆。</p><form id="deleteServerForm"><input type="hidden" id="deleteServerId"><div><label for="deletePassword" class="block text-sm font-medium text-gray-300 mb-2">请输入删除密码</label><input type="password" id="deletePassword" class="w-full bg-gray-700 border border-gray-600 rounded-lg px-3 py-2 text-white focus:ring-red-500 focus:border-red-500" required></div><div class="flex justify-end space-x-4 mt-8"><button type="button" data-action="close" class="bg-gray-600 hover:bg-gray-700 text-white font-bold py-2 px-4 rounded-lg">取消</button><button type="submit" class="bg-red-600 hover:bg-red-700 text-white font-bold py-2 px-4 rounded-lg">确认删除</button></div></form></div></div><script>document.addEventListener("DOMContentLoaded",(()=>{lucide.createIcons();const e=document.getElementById("server-grid"),t=document.getElementById("server-card-template");let o=[];const n="https://YOUR_API_DOMAIN/api",a=1073741824,r=(e,t=2)=>{if(0===e)return"0 Bytes";const o=1024,n=t<0?0:n,a=["Bytes","KB","MB","GB","TB","PB"],r=Math.floor(Math.log(e)/Math.log(o));return parseFloat((e/Math.pow(o,r)).toFixed(n))+" "+a[r]},s=e=>e<1024?`${e.toFixed(1)} B/s`:e<1024*1024?`${(e/1024).toFixed(1)} KB/s`:`${(e/1024/1024).toFixed(1)} MB/s`;async function i(){try{const a=await fetch(`${n}/servers`);if(!a.ok)return void console.error("无法从后端获取数据");o=await a.json(),o.sort(((e,t)=>e.name.localeCompare(t.name))),d()}catch(e){console.error("获取服务器数据时出错:",e)}}function d(){e.innerHTML="",o.forEach((o=>{const n=t.content.cloneNode(!0);n.querySelector('[data-id="name"]').textContent=`${o.name} (${o.location})`,n.querySelector('[data-id="os"]').textContent=o.os,n.firstElementChild.dataset.serverId=o.id,e.appendChild(n)})),c(),lucide.createIcons()}function c(){o.forEach((t=>{const o=e.querySelector(`[data-server-id="${t.id}"]`);o&&l(o,t)}))}function l(e,t){const o=e.querySelector('[data-id="status-dot"]'),n=e.querySelector('[data-id="status-text"]');o.className=t.online?"status-dot status-online":"status-dot status-offline",n.textContent=t.online?"在线":"离线",n.classList.toggle("text-green-400",t.online),n.classList.toggle("text-red-400",!t.online);const a=t.cpu?t.cpu.toFixed(1):"0.0";e.querySelector('[data-id="cpu-usage"]').textContent=`${a}%`,e.querySelector('[data-id="cpu-bar"]').style.width=`${a}%`;const i=t.mem?t.mem.used:0,d=t.mem?t.mem.total:0;e.querySelector('[data-id="mem-usage"]').textContent=`${r(1024*i*1024,0)} / ${r(1024*d*1024,0)}`,e.querySelector('[data-id="mem-bar"]').style.width=d>0?`${i/d*100}%`:"0%";const c=t.disk?t.disk.used:0,l=t.disk?t.disk.total:0;e.querySelector('[data-id="disk-usage"]').textContent=`${c} GB / ${l} GB`,e.querySelector('[data-id="disk-bar"]').style.width=l>0?`${c/l*100}%`:"0%";const u=t.net?t.net.down:0,m=t.net?t.net.up:0;e.querySelector('[data-id="net-down"]').textContent=s(u),e.querySelector('[data-id="net-up"]').textContent=s(m);const p=t.online&&t.startTime?Date.now()-t.startTime:0,f=Math.floor(p/864e5),g=Math.floor(p%864e5/36e5);e.querySelector('[data-id="uptime"]').textContent=t.online?`在线 ${f} 天 ${g} 小时`:"离线";const h=t.totalNet?t.totalNet.up:0,b=t.totalNet?t.totalNet.down:0;e.querySelector('[data-id="total-net-up"]').textContent=r(h,2),e.querySelector('[data-id="total-net-down"]').textContent=r(b,2),e.querySelector('[data-id="reset-info"]').textContent=`每月${t.resetDay||1}日重置`}const u=document.getElementById("addServerModal"),m=document.getElementById("serverSettingsModal"),p=document.getElementById("deleteServerModal");function f(e){const t=o.find((t=>t.id==e));t&&(document.getElementById("settingServerId").value=e,document.getElementById("manualTotalUp").value=(t.totalNet.up/a).toFixed(2),document.getElementById("manualTotalDown").value=(t.totalNet.down/a).toFixed(2),document.getElementById("resetDay").value=t.resetDay,m.style.display="flex")}function g(e){const t=o.find((t=>t.id==e));t&&(document.getElementById("deleteServerName").textContent=t.name,document.getElementById("deleteServerId").value=e,p.style.display="flex")}document.getElementById("addServerBtn").addEventListener("click",(()=>u.style.display="flex")),document.body.addEventListener("click",(e=>{const t=e.target.closest("[data-action]");if(t){const o=t.dataset.action,n=t.closest(".modal-backdrop");"close"===o&&n?n.style.display="none":"settings"===o?(f(t.closest("[data-server-id]").dataset.serverId),lucide.createIcons()):"delete"===o&&(g(t.closest("[data-server-id]").dataset.serverId),lucide.createIcons())}})),document.getElementById("addServerForm").addEventListener("submit",(e=>{e.preventDefault(),u.style.display="none"})),document.getElementById("serverSettingsForm").addEventListener("submit",(async e=>{e.preventDefault();const t=document.getElementById("settingServerId").value;if(o.find((e=>e.id==t))){const o={totalNetUp:parseFloat(document.getElementById("manualTotalUp").value)*a,totalNetDown:parseFloat(document.getElementById("manualTotalDown").value)*a,resetDay:parseInt(document.getElementById("resetDay").value)};try{await fetch(`${n}/servers/${t}/settings`,{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify(o)})}catch(e){console.error("保存设置失败:",e)}}m.style.display="none",i()})),document.getElementById("deleteServerForm").addEventListener("submit",(async e=>{e.preventDefault();const t=document.getElementById("deleteServerId").value,o=document.getElementById("deletePassword").value;if(!o)return void alert("请输入密码！");try{const e=await fetch(`${n}/servers/${t}`,{method:"DELETE",headers:{"Content-Type":"application/json"},body:JSON.stringify({password:o})});if(e.ok)alert("服务器删除成功！"),p.style.display="none",i();else{const t=await e.text();alert(`删除失败: ${t}`)}}catch(e){alert(`请求失败: ${e}`)}finally{document.getElementById("deletePassword").value=""}})),i(),setInterval(i,5e3)}));</script></body></html>
EOF
    sudo sed -i "s|https://YOUR_API_DOMAIN/api|https://$DOMAIN/api|g" /var/www/monitor-frontend/index.html

    # 6. 部署后端 (内置文件)
    echo "--> 正在部署后端API服务..."
    sudo mkdir -p /opt/monitor-backend
    sudo tee /opt/monitor-backend/package.json > /dev/null <<'EOF'
{
  "name": "monitor-backend",
  "version": "1.0.0",
  "description": "Backend for server monitor panel",
  "main": "server.js",
  "scripts": { "start": "node server.js" },
  "dependencies": { "cors": "^2.8.5", "dotenv": "^16.4.5", "express": "^4.19.2" }
}
EOF
    sudo tee /opt/monitor-backend/server.js > /dev/null <<'EOF'
require('dotenv').config();
const express = require('express');
const cors = require('cors');
const app = express();
const PORT = 3000;

const DELETE_PASSWORD = process.env.DELETE_PASSWORD; 
const AGENT_INSTALL_PASSWORD = process.env.AGENT_INSTALL_PASSWORD;

if (!DELETE_PASSWORD || !AGENT_INSTALL_PASSWORD) {
    console.error("错误：DELETE_PASSWORD 或 AGENT_INSTALL_PASSWORD 未在环境变量中设置！");
    process.exit(1);
}

app.use(cors());
app.use(express.json({limit: '1mb'}));

let serverDataStore = {};

app.post('/api/report', (req, res) => {
    try {
        const data = req.body;
        if (!data || !data.id || !data.rawTotalNet || typeof data.rawTotalNet.up === 'undefined' || typeof data.rawTotalNet.down === 'undefined') {
            return res.status(400).send('Invalid data payload.');
        }
        const now = Date.now();
        const existingData = serverDataStore[data.id];
        console.log(`Received report from: ${data.id}`);
        if (!existingData) {
            serverDataStore[data.id] = { ...data, totalNet: { up: 0, down: 0 }, resetDay: 1, lastReset: `${new Date().getFullYear()}-${new Date().getMonth()}`, startTime: now, lastUpdated: now, };
        } else {
            if (existingData.rawTotalNet && typeof existingData.rawTotalNet.up !== 'undefined' && typeof existingData.rawTotalNet.down !== 'undefined') {
                const upBytesSinceLast = data.rawTotalNet.up - existingData.rawTotalNet.up;
                const downBytesSinceLast = data.rawTotalNet.down - existingData.rawTotalNet.down;
                if (upBytesSinceLast > 0) existingData.totalNet.up += upBytesSinceLast;
                if (downBytesSinceLast > 0) existingData.totalNet.down += downBytesSinceLast;
            }
            serverDataStore[data.id] = { ...data, totalNet: existingData.totalNet, resetDay: existingData.resetDay, lastReset: existingData.lastReset, startTime: existingData.startTime, lastUpdated: now, };
        }
        res.status(200).send('Report received.');
    } catch (error) {
        console.error('Error processing report:', error);
        res.status(500).send('Internal Server Error');
    }
});
app.get('/api/servers', (req, res) => {
    const now = Date.now();
    Object.values(serverDataStore).forEach(server => { server.online = (now - server.lastUpdated) < 30000; });
    res.json(Object.values(serverDataStore));
});
app.post('/api/servers/:id/settings', (req, res) => {
    const { id } = req.params; const settings = req.body;
    if (serverDataStore[id]) {
        serverDataStore[id].totalNet.up = settings.totalNetUp;
        serverDataStore[id].totalNet.down = settings.totalNetDown;
        serverDataStore[id].resetDay = settings.resetDay;
        res.status(200).send('Settings updated.');
    } else { res.status(404).send('Server not found.'); }
});
app.delete('/api/servers/:id', (req, res) => {
    const { id } = req.params; const { password } = req.body;
    if (!password) return res.status(400).send('需要提供密码。');
    if (password !== DELETE_PASSWORD) return res.status(403).send('密码错误。');
    if (serverDataStore[id]) {
        delete serverDataStore[id];
        console.log(`服务器 ${id} 已被删除。`);
        res.status(200).send('服务器删除成功。');
    } else { res.status(404).send('未找到该服务器。'); }
});
app.post('/api/verify-agent-password', (req, res) => {
    const { password } = req.body;
    if (password && password === AGENT_INSTALL_PASSWORD) {
        res.status(200).send('被控端安装密码正确。');
    } else { res.status(403).send('被控端安装密码无效。'); }
});
app.listen(PORT, '127.0.0.1', () => {
    console.log(`Monitor backend server running on http://127.0.0.1:${PORT}`);
    setInterval(checkAndResetTraffic, 3600000); 
});
function checkAndResetTraffic() {
    const now = new Date(); const currentDay = now.getDate(); const currentMonthYear = `${now.getFullYear()}-${now.getMonth()}`;
    Object.keys(serverDataStore).forEach(id => {
        const server = serverDataStore[id];
        if (server.resetDay === currentDay && server.lastReset !== currentMonthYear) {
            console.log(`Resetting traffic for server ${id}`);
            server.totalNet = { up: 0, down: 0 };
            server.lastReset = currentMonthYear;
        }
    });
}
EOF
    cd /opt/monitor-backend && sudo npm install

    # 7. 创建环境变量文件
    echo "--> 正在配置后端环境变量..."
    sudo tee /opt/monitor-backend/.env > /dev/null <<EOF
DELETE_PASSWORD=$DEL_PASSWORD
AGENT_INSTALL_PASSWORD=$AGENT_PASSWORD
EOF

    # 8. 创建Systemd服务
    echo "--> 正在创建后台运行服务..."
    sudo tee /etc/systemd/system/monitor-backend.service > /dev/null <<'EOF'
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

    read -p "请输入您的后端API域名 (例如: https://monitor.yourdomain.com): " BACKEND_DOMAIN
    if [ -z "$BACKEND_DOMAIN" ]; then echo -e "${RED}错误：后端域名不能为空！${NC}"; exit 1; fi
    read -s -p "请输入【被控端安装密码】: " AGENT_INSTALL_PASSWORD_INPUT; echo
    
    echo "--> 正在验证安装密码..."
    VERIFY_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" -d "{\"password\":\"$AGENT_INSTALL_PASSWORD_INPUT\"}" "$BACKEND_DOMAIN/api/verify-agent-password")
    if [ "$VERIFY_STATUS" -ne 200 ]; then echo -e "${RED}错误：被控端安装密码错误或无法连接到后端！状态码: $VERIFY_STATUS${NC}"; exit 1; fi
    echo -e "${GREEN}密码验证成功！正在继续安装...${NC}"

    echo "--> 正在安装依赖 (sysstat, bc)..."
    sudo apt-get update
    sudo apt-get install -y sysstat bc
    if [ $? -ne 0 ]; then echo -e "${RED}错误：依赖 'sysstat' 或 'bc' 安装失败。${NC}"; exit 1; fi

    read -p "请为当前服务器设置一个唯一的ID (例如: web-server-01): " SERVER_ID
    read -p "请输入当前服务器的名称 (例如: 亚太-Web服务器): " SERVER_NAME
    read -p "请输入当前服务器的位置 (例如: 新加坡): " SERVER_LOCATION
    
    NET_INTERFACE=$(ip -o -4 route show to default | awk '{print $5}')
    echo "--> 自动检测到网络接口为: $NET_INTERFACE"

    echo "--> 正在部署Agent脚本..."
    sudo mkdir -p /opt/monitor-agent
    sudo tee /opt/monitor-agent/agent.sh > /dev/null <<'EOF'
#!/bin/bash
BACKEND_URL="https://monitor.yourdomain.com/api/report"
SERVER_ID="default-id"
SERVER_NAME="Default Server Name"
SERVER_LOCATION="Default Location"
NET_INTERFACE="eth0"
OS=$(hostnamectl | grep "Operating System" | cut -d: -f2 | xargs)
CPU_USAGE=$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1}')
MEM_INFO=$(free -m | grep Mem)
MEM_TOTAL=$(echo $MEM_INFO | awk '{print $2}')
MEM_USED=$(echo $MEM_INFO | awk '{print $3}')
DISK_INFO=$(df -h / | tail -n 1)
DISK_TOTAL=$(echo $DISK_INFO | awk '{print $2}' | sed 's/G//')
DISK_USED=$(echo $DISK_INFO | awk '{print $3}' | sed 's/G//')
NET_STATS=$(sar -n DEV 1 1 | grep "Average:" | grep $NET_INTERFACE || echo "Average: $NET_INTERFACE 0 0 0 0 0 0 0 0")
NET_DOWN_KBPS=$(echo $NET_STATS | awk '{print $5}')
NET_UP_KBPS=$(echo $NET_STATS | awk '{print $6}')   
NET_DOWN_BPS=$(echo "$NET_DOWN_KBPS * 1024" | bc)
NET_UP_BPS=$(echo "$NET_UP_KBPS * 1024" | bc)
RAW_TOTAL_NET_DOWN=$(cat /sys/class/net/$NET_INTERFACE/statistics/rx_bytes)
RAW_TOTAL_NET_UP=$(cat /sys/class/net/$NET_INTERFACE/statistics/tx_bytes)
JSON_PAYLOAD=$(cat <<EOF
{"id":"$SERVER_ID","name":"$SERVER_NAME","location":"$SERVER_LOCATION","os":"$OS","cpu":$CPU_USAGE,"mem":{"total":$MEM_TOTAL,"used":$MEM_USED},"disk":{"total":$DISK_TOTAL,"used":$DISK_USED},"net":{"up":$NET_UP_BPS,"down":$NET_DOWN_BPS},"rawTotalNet":{"up":$RAW_TOTAL_NET_UP,"down":$RAW_TOTAL_NET_DOWN}}
EOF
)
curl -s -X POST -H "Content-Type: application/json" -d "$JSON_PAYLOAD" $BACKEND_URL
EOF
    sudo chmod +x /opt/monitor-agent/agent.sh

    sudo sed -i "s|BACKEND_URL=.*|BACKEND_URL=\"$BACKEND_DOMAIN/api/report\"|g" /opt/monitor-agent/agent.sh
    sudo sed -i "s|SERVER_ID=.*|SERVER_ID=\"$SERVER_ID\"|g" /opt/monitor-agent/agent.sh
    sudo sed -i "s|SERVER_NAME=.*|SERVER_NAME=\"$SERVER_NAME\"|g" /opt/monitor-agent/agent.sh
    sudo sed -i "s|SERVER_LOCATION=.*|SERVER_LOCATION=\"$SERVER_LOCATION\"|g" /opt/monitor-agent/agent.sh
    sudo sed -i "s|NET_INTERFACE=.*|NET_INTERFACE=\"$NET_INTERFACE\"|g" /opt/monitor-agent/agent.sh
    
    echo "--> 正在创建后台上报服务..."
    sudo tee /etc/systemd/system/monitor-agent.service > /dev/null <<'EOF'
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
    if [ -z "$DOMAIN" ]; then echo -e "${RED}错误：域名不能为空！${NC}"; exit 1; fi
    read -p "您确定要删除所有相关文件和服务吗? [y/N]: " CONFIRM
    if [[ "$CONFIRM" != "y" ]]; then echo "操作已取消。"; exit 0; fi

    echo "--> 正在停止并禁用服务..."
    sudo systemctl stop monitor-backend.service nginx
    sudo systemctl disable monitor-backend.service > /dev/null 2>&1
    
    echo "--> 正在删除文件和配置..."
    sudo rm -rf /opt/monitor-backend /var/www/monitor-frontend
    sudo rm -f /etc/systemd/system/monitor-backend.service "/etc/nginx/sites-available/$DOMAIN" "/etc/nginx/sites-enabled/$DOMAIN"
    
    echo "--> 正在重载服务..."
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
    read -p "您确定要停止并删除本服务器上的监控Agent吗? [y/N]: " CONFIRM
    if [[ "$CONFIRM" != "y" ]]; then echo "操作已取消。"; exit 0; fi

    echo "--> 正在停止并禁用Agent服务..."
    sudo systemctl stop monitor-agent.service
    sudo systemctl disable monitor-agent.service > /dev/null 2>&1
    
    echo "--> 正在删除Agent文件..."
    sudo rm -rf /opt/monitor-agent
    sudo rm -f /etc/systemd/system/monitor-agent.service
    
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
" and am asking a query about/based on this code below.
Instructions to follow:
  * Don't output/edit the document if the query is Direct/Simple. For example, if the query asks for a simple explanation, output a direct answer.
  * Make sure to **edit** the document if the query shows the intent of editing the document, in which case output the entire edited document, **not just that section or the edits**.
    * Don't output the same document/empty document and say that you have edited it.
    * Don't change unrelated code in the document.
  * Don't output  and  in your final response.
  * Any references like "this" or "selected code" refers to the code between  and  tags.
  * Just acknowledge my request in the introduction.
  * Make sure to refer to the document as "Canvas" in your response.
