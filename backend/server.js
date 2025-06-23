require('dotenv').config(); // 在文件顶部加载环境变量
const express = require('express');
const cors = require('cors');
const fs = require('fs'); // 引入fs模块
const path = require('path'); // 引入path模块
const app = express();
const PORT = 3000;

// 从环境变量读取密码
const DELETE_PASSWORD = process.env.DELETE_PASSWORD;
const AGENT_INSTALL_PASSWORD = process.env.AGENT_INSTALL_PASSWORD; // 被控端安装密码

if (!DELETE_PASSWORD || !AGENT_INSTALL_PASSWORD) {
    console.error("错误：DELETE_PASSWORD 或 AGENT_INSTALL_PASSWORD 未在环境变量中设置！");
    process.exit(1);
}

// --- 数据持久化 ---
const DB_FILE = path.join(__dirname, 'server_data.json');
let serverDataStore = {};

// 启动时加载数据
try {
    if (fs.existsSync(DB_FILE)) {
        const data = fs.readFileSync(DB_FILE, 'utf8');
        serverDataStore = JSON.parse(data);
        console.log(`数据已成功从 ${DB_FILE} 加载。`);
    }
} catch (err) {
    console.error("从文件加载数据时出错:", err);
}

// 保存数据到文件
function saveData() {
    try {
        fs.writeFileSync(DB_FILE, JSON.stringify(serverDataStore, null, 2));
    } catch (err) {
        console.error("保存数据到文件时出错:", err);
    }
}
// --- 数据持久化结束 ---

app.use(cors());
app.use(express.json({limit: '1mb'}));

// POST /api/report
app.post('/api/report', (req, res) => {
    const data = req.body;
    if (!data.id) {
        return res.status(400).send('Server ID is required.');
    }

    const now = Date.now();
    const existingData = serverDataStore[data.id];

    if (!existingData) {
        // 新服务器首次上报
        const now_date = new Date();
        serverDataStore[data.id] = {
            ...data,
            totalNet: { up: 0, down: 0 },
            resetDay: 1,
            // 使用YYYY-M 格式记录上次重置的月份
            lastReset: `${now_date.getFullYear()}-${now_date.getMonth() + 1}`, 
            startTime: now,
            lastUpdated: now,
            online: true,
            expirationDate: null // 新增：为新服务器初始化到期日期
        };
    } else {
        // 已有服务器更新数据
        let upBytesSinceLast = 0;
        let downBytesSinceLast = 0;
        
        // 健壮性检查：确保rawTotalNet存在且值是增长的 (防止agent重启导致计数重置)
        if (existingData.rawTotalNet && data.rawTotalNet.up >= existingData.rawTotalNet.up) {
            upBytesSinceLast = data.rawTotalNet.up - existingData.rawTotalNet.up;
        }
        if (existingData.rawTotalNet && data.rawTotalNet.down >= existingData.rawTotalNet.down) {
            downBytesSinceLast = data.rawTotalNet.down - existingData.rawTotalNet.down;
        }
        
        existingData.totalNet.up += upBytesSinceLast;
        existingData.totalNet.down += downBytesSinceLast;

        // 合并新旧数据
        serverDataStore[data.id] = {
            ...existingData, // 保留旧的设置如 totalNet, resetDay, expirationDate等
            ...data,         // 使用agent上报的最新动态数据覆盖
            totalNet: existingData.totalNet, // 确保 totalNet 不被覆盖
            expirationDate: existingData.expirationDate, // 确保 expirationDate 不被agent上报的数据覆盖
            lastUpdated: now,
            online: true
        };
    }

    saveData(); // 保存数据
    res.status(200).send('Report received.');
});

// GET /api/servers
app.get('/api/servers', (req, res) => {
    const now = Date.now();
    // 检查所有服务器的在线状态
    Object.values(serverDataStore).forEach(server => {
        // 如果超过30秒没有更新，则认为离线
        server.online = (now - server.lastUpdated) < 30000; 
    });
    res.json(Object.values(serverDataStore));
});

// POST /api/servers/:id/settings - 现在需要被控端安装密码和到期日期
app.post('/api/servers/:id/settings', (req, res) => {
    const { id } = req.params;
    const { totalNetUp, totalNetDown, resetDay, password, expirationDate } = req.body; // 添加 password 和 expirationDate
    
    // 验证被控端安装密码
    if (!password || password !== AGENT_INSTALL_PASSWORD) {
        return res.status(403).send('被控端安装密码不正确。');
    }

    if (serverDataStore[id]) {
        serverDataStore[id].totalNet.up = totalNetUp;
        serverDataStore[id].totalNet.down = totalNetDown;
        serverDataStore[id].resetDay = resetDay;
        serverDataStore[id].expirationDate = expirationDate; // 保存到期日期
        saveData(); // 保存数据
        res.status(200).send('设置更新成功。');
    } else {
        res.status(404).send('未找到服务器。');
    }
});

// DELETE /api/servers/:id
app.delete('/api/servers/:id', (req, res) => {
    const { id } = req.params;
    const { password } = req.body;

    if (!password) return res.status(400).send('需要提供密码。');
    if (password !== DELETE_PASSWORD) return res.status(403).send('密码错误。');

    if (serverDataStore[id]) {
        delete serverDataStore[id];
        saveData(); // 保存数据
        console.log(`服务器 ${id} 已被删除。`);
        res.status(200).send('服务器删除成功。');
    } else {
        res.status(404).send('未找到该服务器。');
    }
});

// POST /api/verify-agent-password
app.post('/api/verify-agent-password', (req, res) => {
    const { password } = req.body;
    if (password && password === AGENT_INSTALL_PASSWORD) {
        res.status(200).send('被控端安装密码正确。');
    } else {
        res.status(403).send('被控端安装密码无效。');
    }
});

// 流量重置检查函数
function checkAndResetTraffic() {
    const now = new Date();
    const currentDay = now.getDate();
    // 使用YYYY-M 格式
    const currentMonthYear = `${now.getFullYear()}-${now.getMonth() + 1}`;
    let changed = false;

    console.log(`[${new Date().toISOString()}] Running daily traffic reset check...`);

    Object.keys(serverDataStore).forEach(id => {
        const server = serverDataStore[id];
        // 检查是否到达重置日，并且本月尚未重置
        if (server.resetDay === currentDay && server.lastReset !== currentMonthYear) {
            console.log(`正在为服务器 ${id} 重置流量...`);
            server.totalNet = { up: 0, down: 0 };
            server.lastReset = currentMonthYear;
            changed = true;
        }
    });

    if (changed) {
        console.log("流量重置完成，正在保存数据...");
        saveData();
    }
}


app.listen(PORT, '0.0.0.0', () => { // Changed from '127.0.0.1' to '0.0.0.0'
    console.log(`Monitor backend server running on http://0.0.0.0:${PORT}`); // Updated console log message
    // 每小时检查一次是否需要重置流量
    setInterval(checkAndResetTraffic, 1000 * 60 * 60); 
    // 启动时立即执行一次检查
    checkAndResetTraffic();
});
