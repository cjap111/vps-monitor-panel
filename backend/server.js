// server.js
require('dotenv').config();
const express = require('express');
const cors = require('cors');
const fs = require('fs');
const path = require('path');
const app = express();
const PORT = 3000;

// 从环境变量读取密码
const DELETE_PASSWORD = process.env.DELETE_PASSWORD;
const AGENT_INSTALL_PASSWORD = process.env.AGENT_INSTALL_PASSWORD;

if (!DELETE_PASSWORD || !AGENT_INSTALL_PASSWORD) {
    console.error("错误: 环境变量中未设置 DELETE_PASSWORD 或 AGENT_INSTALL_PASSWORD！");
    process.exit(1);
}

// --- 数据持久化 ---
const DB_FILE = path.join(__dirname, 'server_data.json');
let serverDataStore = {};

// 启动时加载数据
try {
    if (fs.existsSync(DB_FILE)) {
        const data = fs.readFileSync(DB_File, 'utf8');
        const loadedData = JSON.parse(data);
        serverDataStore = loadedData;
        console.log(`[${new Date().toISOString()}] 数据成功从 ${DB_FILE} 加载。`);
        
        // 修复：确保旧数据在加载时具有所有必需的字段，防止出错
        Object.keys(serverDataStore).forEach(id => {
            const server = serverDataStore[id];
            if (!server.rawTotalNet) server.rawTotalNet = { up: 0, down: 0 };
            if (!server.totalNet) server.totalNet = { up: 0, down: 0 };
            if (server.totalTrafficLimit === undefined) server.totalTrafficLimit = 0;
            if (!server.trafficCalculationMode) server.trafficCalculationMode = 'bidirectional';
            if (server.resetDay === undefined) server.resetDay = 1;
            if (server.resetHour === undefined) server.resetHour = 0;
            if (server.resetMinute === undefined) server.resetMinute = 0;
            if (server.lastReset === undefined || server.lastReset === null) {
                // 为没有 lastReset 的旧服务器设置一个合理的初始值
                const now = new Date();
                const resetDateThisMonth = new Date(now.getFullYear(), now.getMonth(), server.resetDay, server.resetHour, server.resetMinute);
                if (now < resetDateThisMonth) {
                    // 如果本月重置日还没到，则将上次重置时间设为上个月的重置日
                    server.lastReset = new Date(now.getFullYear(), now.getMonth() - 1, server.resetDay, server.resetHour, server.resetMinute).getTime();
                } else {
                    // 如果本月重置日已过，则设为本月的重置日
                    server.lastReset = resetDateThisMonth.getTime();
                }
            }
        });

    } else {
        console.log(`[${new Date().toISOString()}] 未找到数据文件 ${DB_FILE}。将使用空数据存储启动。`);
    }
} catch (err) {
    console.error(`[${new Date().toISOString()}] 从文件 ${DB_FILE} 加载或解析数据时出错:`, err);
    serverDataStore = {}; // 如果加载失败，确保从空状态开始
}

// 保存数据到文件
function saveData() {
    try {
        fs.writeFileSync(DB_FILE, JSON.stringify(serverDataStore, null, 2));
    } catch (err) {
        console.error(`[${new Date().toISOString()}] 保存数据到文件 ${DB_FILE} 时出错:`, err);
    }
}
// --- 结束数据持久化 ---

app.use(cors());
app.use(express.json({ limit: '1mb' }));

// --- 路由 ---

// POST /api/report - 从Agent接收监控数据
app.post('/api/report', (req, res) => {
    const data = req.body;
    if (!data.id) {
        return res.status(400).send('需要服务器ID。');
    }

    const now = Date.now();
    let existingData = serverDataStore[data.id];

    // 修复：改进了数据更新逻辑，以保留现有流量统计
    if (!existingData) {
        // 如果是新服务器，则初始化所有数据
        const now = new Date();
        const resetDay = data.resetDay !== undefined ? data.resetDay : 1;
        const resetHour = data.resetHour !== undefined ? data.resetHour : 0;
        const resetMinute = data.resetMinute !== undefined ? data.resetMinute : 0;
        const resetDateThisMonth = new Date(now.getFullYear(), now.getMonth(), resetDay, resetHour, resetMinute);
        let lastReset;
        if (now < resetDateThisMonth) {
            lastReset = new Date(now.getFullYear(), now.getMonth() - 1, resetDay, resetHour, resetMinute).getTime();
        } else {
            lastReset = resetDateThisMonth.getTime();
        }

        existingData = {
            ...data,
            rawTotalNet: { up: data.rawTotalNet.up, down: data.rawTotalNet.down },
            totalNet: { up: 0, down: 0 }, // 新服务器流量从0开始
            resetDay: resetDay,
            resetHour: resetHour,
            resetMinute: resetMinute,
            lastReset: lastReset,
            lastUpdated: now,
            online: true,
            totalTrafficLimit: 0,
            trafficCalculationMode: 'bidirectional'
        };
        console.log(`[${new Date().toISOString()}] 添加新服务器 ${data.id}。`);
    } else {
        // 如果是现有服务器，则只更新动态数据，保留累计流量和设置
        let upBytesSinceLast = 0;
        let downBytesSinceLast = 0;

        // 处理网卡计数器重置（例如服务器重启）
        if (data.rawTotalNet.up < existingData.rawTotalNet.up) {
            upBytesSinceLast = data.rawTotalNet.up; // 计数器重置，增量就是当前值
        } else {
            upBytesSinceLast = data.rawTotalNet.up - existingData.rawTotalNet.up;
        }

        if (data.rawTotalNet.down < existingData.rawTotalNet.down) {
            downBytesSinceLast = data.rawTotalNet.down;
        } else {
            downBytesSinceLast = data.rawTotalNet.down - existingData.rawTotalNet.down;
        }
        
        // 更新累计流量
        existingData.totalNet.up += Math.max(0, upBytesSinceLast);
        existingData.totalNet.down += Math.max(0, downBytesSinceLast);

        // 更新服务器的其他信息
        existingData = {
            ...existingData, // 保留旧设置，如 resetDay, totalTrafficLimit等
            ...data, // 使用新上报的动态数据覆盖
            totalNet: existingData.totalNet, // 明确保留更新后的累计流量
            rawTotalNet: { up: data.rawTotalNet.up, down: data.rawTotalNet.down }, // 更新原始计数器以备下次比较
            lastUpdated: now,
            online: true,
        };
    }

    serverDataStore[data.id] = existingData;
    saveData();
    res.status(200).send('报告已收到。');
});

// GET /api/servers - 为前端获取所有服务器数据
app.get('/api/servers', (req, res) => {
    const now = Date.now();
    // 检查在线状态，15秒内无更新则视为离线
    Object.values(serverDataStore).forEach(server => {
        server.online = (now - server.lastUpdated) < 15000;
    });
    res.json(Object.values(serverDataStore));
});

// POST /api/servers/:id/settings - 更新服务器设置
app.post('/api/servers/:id/settings', (req, res) => {
    const { id } = req.params;
    const { password, ...settings } = req.body;

    if (password !== AGENT_INSTALL_PASSWORD) {
        return res.status(403).send('被控端安装密码不正确。');
    }

    if (serverDataStore[id]) {
        // 如果重置设置有变化，则重新计算 lastReset
        const server = serverDataStore[id];
        if (server.resetDay !== settings.resetDay || server.resetHour !== settings.resetHour || server.resetMinute !== settings.resetMinute) {
            const now = new Date();
            const resetDateThisMonth = new Date(now.getFullYear(), now.getMonth(), settings.resetDay, settings.resetHour, settings.resetMinute);
            if (now < resetDateThisMonth) {
                settings.lastReset = new Date(now.getFullYear(), now.getMonth() - 1, settings.resetDay, settings.resetHour, settings.resetMinute).getTime();
            } else {
                settings.lastReset = resetDateThisMonth.getTime();
            }
        }
        
        serverDataStore[id] = { ...server, ...settings };
        saveData();
        res.status(200).send('设置更新成功。');
    } else {
        res.status(404).send('未找到服务器。');
    }
});

// DELETE /api/servers/:id - 删除服务器
app.delete('/api/servers/:id', (req, res) => {
    const { id } = req.params;
    const { password } = req.body;

    if (password !== DELETE_PASSWORD) {
        return res.status(403).send('删除密码不正确。');
    }

    if (serverDataStore[id]) {
        delete serverDataStore[id];
        saveData();
        res.status(200).send('服务器删除成功。');
    } else {
        res.status(404).send('未找到服务器。');
    }
});

// POST /api/verify-agent-password - 验证被控端安装密码
app.post('/api/verify-agent-password', (req, res) => {
    const { password } = req.body;
    if (password === AGENT_INSTALL_PASSWORD) {
        res.status(200).send('被控端安装密码正确。');
    } else {
        res.status(403).send('无效的被控端安装密码。');
    }
});

// 修复：重写流量重置检查函数，逻辑更清晰可靠
function checkAndResetTraffic() {
    const now = new Date();
    let changed = false;

    console.log(`\n[${now.toISOString()}] 正在运行每小时流量重置检查...`);

    Object.keys(serverDataStore).forEach(id => {
        const server = serverDataStore[id];
        if (server.lastReset === undefined || server.lastReset === null) return; // 跳过没有设置的

        const lastResetDate = new Date(server.lastReset);
        const resetDay = server.resetDay || 1;
        const resetHour = server.resetHour || 0;
        const resetMinute = server.resetMinute || 0;

        // 计算下一次重置的准确时间点
        let nextResetDate = new Date(lastResetDate.getFullYear(), lastResetDate.getMonth(), resetDay, resetHour, resetMinute);
        if (nextResetDate <= lastResetDate) {
             // 如果计算出的下次重置时间小于等于上次重置时间，说明应该在下个月
             nextResetDate.setMonth(nextResetDate.getMonth() + 1);
        }
        
        console.log(`  [服务器 ${id}] 上次重置: ${lastResetDate.toISOString()}, 下次计划重置: ${nextResetDate.toISOString()}`);

        if (now >= nextResetDate) {
            console.log(`  -> 需要重置！当前时间已超过下次计划重置时间。`);
            server.totalNet = { up: 0, down: 0 };
            server.lastReset = now.getTime(); // 将lastReset更新为当前时间
            changed = true;
        }
    });

    if (changed) {
        console.log(`[${now.toISOString()}] 流量重置完成，正在保存数据...`);
        saveData();
    } else {
        console.log(`[${now.toISOString()}] 没有服务器需要重置流量。`);
    }
}


// 启动服务器并设置每小时流量重置检查
app.listen(PORT, '0.0.0.0', () => {
    console.log(`[${new Date().toISOString()}] 监控后端服务器正在 http://0.0.0.0:${PORT} 上运行`);
    // 每小时检查一次
    setInterval(checkAndResetTraffic, 1000 * 60 * 60); 
    // 启动时立即运行一次检查
    checkAndResetTraffic();
});
