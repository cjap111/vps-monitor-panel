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

// POST /api/report (无变化)
app.post('/api/report', (req, res) => { /* ... */ });

// GET /api/servers (无变化)
app.get('/api/servers', (req, res) => { /* ... */ });

// POST /api/servers/:id/settings (无变化)
app.post('/api/servers/:id/settings', (req, res) => { /* ... */ });

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

// 新增：POST /api/verify-agent-password
app.post('/api/verify-agent-password', (req, res) => {
    const { password } = req.body;
    if (password && password === AGENT_INSTALL_PASSWORD) {
        res.status(200).send('被控端安装密码正确。');
    } else {
        res.status(403).send('被控端安装密码无效。');
    }
});

app.listen(PORT, '127.0.0.1', () => { /* ... */ });

function checkAndResetTraffic() { /* ... */ }
