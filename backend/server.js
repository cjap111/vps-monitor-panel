require('dotenv').config(); // 在文件顶部加载环境变量
const express = require('express');
const cors = require('cors');
const fs = require('fs'); // 引入fs模块
const path = require('path'); // 引入path模块
const app = express();
const PORT = 3000;

// 从环境变量读取密码
const DELETE_PASSWORD = process.env.DELETE_PASSWORD;
const AGENT_INSTALL_PASSWORD = process.env.AGENT_INSTALL_PASSWORD;

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
        const data = fs.readFileSync(DB_FILE);
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
        // New server
        serverDataStore[data.id] = {
            ...data,
            totalNet: { up: 0, down: 0 },
            resetDay: 1,
            lastReset: `${new Date().getFullYear()}-${new Date().getMonth()}`,
            startTime: now,
            lastUpdated: now,
        };
    } else {
        // Existing server
        const upBytesSinceLast = data.rawTotalNet.up - (existingData.rawTotalNet ? existingData.rawTotalNet.up : 0);
        const downBytesSinceLast = data.rawTotalNet.down - (existingData.rawTotalNet ? existingData.rawTotalNet.down : 0);

        if (upBytesSinceLast > 0) {
            existingData.totalNet.up += upBytesSinceLast;
        }
        if (downBytesSinceLast > 0) {
            existingData.totalNet.down += downBytesSinceLast;
        }

        serverDataStore[data.id] = {
            ...data,
            totalNet: existingData.totalNet,
            resetDay: existingData.resetDay,
            lastReset: existingData.lastReset,
            startTime: existingData.startTime,
            lastUpdated: now,
        };
    }

    saveData(); // 保存数据
    res.status(200).send('Report received.');
});

// GET /api/servers
app.get('/api/servers', (req, res) => {
    const now = Date.now();
    Object.values(serverDataStore).forEach(server => {
        server.online = (now - server.lastUpdated) < 30000;
    });
    res.json(Object.values(serverDataStore));
});

// POST /api/servers/:id/settings
app.post('/api/servers/:id/settings', (req, res) => {
    const { id } = req.params;
    const settings = req.body;
    if (serverDataStore[id]) {
        serverDataStore[id].totalNet.up = settings.totalNetUp;
        serverDataStore[id].totalNet.down = settings.totalNetDown;
        serverDataStore[id].resetDay = settings.resetDay;
        saveData(); // 保存数据
        res.status(200).send('Settings updated.');
    } else {
        res.status(404).send('Server not found.');
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

app.listen(PORT, '127.0.0.1', () => {
    console.log(`Monitor backend server running on http://127.0.0.1:${PORT}`);
    setInterval(checkAndResetTraffic, 1000 * 60 * 60); 
});

function checkAndResetTraffic() {
    const now = new Date();
    const currentDay = now.getDate();
    const currentMonthYear = `${now.getFullYear()}-${now.getMonth()}`;
    let changed = false;

    Object.keys(serverDataStore).forEach(id => {
        const server = serverDataStore[id];
        if (server.resetDay === currentDay && server.lastReset !== currentMonthYear) {
            console.log(`Resetting traffic for server ${id}`);
            server.totalNet = { up: 0, down: 0 };
            server.lastReset = currentMonthYear;
            changed = true;
        }
    });

    if (changed) {
        saveData(); // 如果有流量重置，保存数据
    }
}
