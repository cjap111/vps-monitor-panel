require('dotenv').config(); // 在文件顶部加载环境变量
const express = require('express');
const cors = require('cors');
const app = express();
const PORT = 3000;

// 从环境变量读取密码
const DELETE_PASSWORD = process.env.DELETE_PASSWORD; 
const AGENT_INSTALL_PASSWORD = process.env.AGENT_INSTALL_PASSWORD;

if (!DELETE_PASSWORD || !AGENT_INSTALL_PASSWORD) {
    console.error("错误：DELETE_PASSWORD 或 AGENT_INSTALL_PASSWORD 未在环境变量中设置！");
    process.exit(1);
}

app.use(cors());
app.use(express.json({limit: '1mb'}));

let serverDataStore = {};

// POST /api/report - 已修复潜在的崩溃bug
app.post('/api/report', (req, res) => {
    try {
        const data = req.body;
        if (!data || !data.id || !data.rawTotalNet) {
            return res.status(400).send('Invalid data payload.');
        }

        const now = Date.now();
        const existingData = serverDataStore[data.id];

        // 使用 console.log 确认数据已到达
        console.log(`Received report from: ${data.id}`);

        if (!existingData) {
            // 这是新服务器的第一次上报
            serverDataStore[data.id] = {
                ...data,
                totalNet: { up: 0, down: 0 }, // 累计流量从0开始
                resetDay: 1,
                lastReset: `${new Date().getFullYear()}-${new Date().getMonth()}`,
                startTime: now, // 记录首次上报时间
                lastUpdated: now,
            };
        } else {
            // 这是已存在服务器的更新
            // 安全地计算流量增量，防止agent重启导致数据错误
            const upBytesSinceLast = data.rawTotalNet.up - (existingData.rawTotalNet.up || 0);
            const downBytesSinceLast = data.rawTotalNet.down - (existingData.rawTotalNet.down || 0);
            
            if (upBytesSinceLast > 0) {
                existingData.totalNet.up += upBytesSinceLast;
            }
            if (downBytesSinceLast > 0) {
                existingData.totalNet.down += downBytesSinceLast;
            }
    
            // 更新数据，同时保留首次上报时间和累计流量
            serverDataStore[data.id] = {
                ...data,
                totalNet: existingData.totalNet,
                resetDay: existingData.resetDay,
                lastReset: existingData.lastReset,
                startTime: existingData.startTime, 
                lastUpdated: now,
            };
        }
        
        res.status(200).send('Report received.');

    } catch (error) {
        console.error('Error processing report:', error);
        res.status(500).send('Internal Server Error');
    }
});

// GET /api/servers
app.get('/api/servers', (req, res) => {
    const now = Date.now();
    Object.values(serverDataStore).forEach(server => {
        // 如果超过30秒没有更新，则视为离线
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

    Object.keys(serverDataStore).forEach(id => {
        const server = serverDataStore[id];
        if (server.resetDay === currentDay && server.lastReset !== currentMonthYear) {
            console.log(`Resetting traffic for server ${id}`);
            server.totalNet = { up: 0, down: 0 };
            server.lastReset = currentMonthYear;
        }
    });
}
