require('dotenv').config(); // Load environment variables at the top of the file
const express = require('express');
const cors = require('cors');
const fs = require('fs'); // Import fs module
const path = require('path'); // Import path module
const app = express();
const PORT = 3000;

// Read passwords from environment variables
const DELETE_PASSWORD = process.env.DELETE_PASSWORD;
const AGENT_INSTALL_PASSWORD = process.env.AGENT_INSTALL_PASSWORD; // Agent installation password

if (!DELETE_PASSWORD || !AGENT_INSTALL_PASSWORD) {
    console.error("Error: DELETE_PASSWORD or AGENT_INSTALL_PASSWORD not set in environment variables!");
    process.exit(1);
}

// --- Data Persistence ---
const DB_FILE = path.join(__dirname, 'server_data.json');
let serverDataStore = {};

// Load data on startup
try {
    if (fs.existsSync(DB_FILE)) {
        const data = fs.readFileSync(DB_FILE, 'utf8');
        serverDataStore = JSON.parse(data);
        console.log(`Data successfully loaded from ${DB_FILE}.`);
        // Ensure data structures are initialized correctly on load
        Object.keys(serverDataStore).forEach(id => {
            if (!serverDataStore[id].rawTotalNet) {
                serverDataStore[id].rawTotalNet = { up: 0, down: 0 };
            }
            if (!serverDataStore[id].totalNet) {
                serverDataStore[id].totalNet = { up: 0, down: 0 };
            }
            if (serverDataStore[id].totalTrafficLimit === undefined) {
                serverDataStore[id].totalTrafficLimit = 0;
            }
            if (serverDataStore[id].trafficCalculationMode === undefined) {
                serverDataStore[id].trafficCalculationMode = 'bidirectional';
            }
            if (serverDataStore[id].systemUptime === undefined) {
                serverDataStore[id].systemUptime = 0;
            }
            if (serverDataStore[id].resetDay === undefined) {
                serverDataStore[id].resetDay = 1;
            }
            if (serverDataStore[id].resetHour === undefined) {
                serverDataStore[id].resetHour = 0;
            }
            if (serverDataStore[id].resetMinute === undefined) {
                serverDataStore[id].resetMinute = 0;
            }
             // lastReset will be handled by the new logic, no need for complex initialization here.
        });
        saveData();
    }
} catch (err) {
    console.error("Error loading data from file:", err);
}

// Save data to file
function saveData() {
    try {
        fs.writeFileSync(DB_FILE, JSON.stringify(serverDataStore, null, 2));
    } catch (err) {
        console.error("Error saving data to file:", err);
    }
}
// --- End Data Persistence ---

app.use(cors());
app.use(express.json({limit: '1mb'}));
app.use(express.urlencoded({ extended: true, limit: '1mb' }));

// --- Routes ---

app.get('/', (req, res) => {
    res.status(200).send('Monitor Backend is running!');
});

app.post('/api/report', (req, res) => {
    const data = req.body;
    if (!data.id) {
        console.error(`[${new Date().toISOString()}] Error: Server ID is required for report.`);
        return res.status(400).send('Server ID is required.');
    }

    const now = Date.now();
    let existingData = serverDataStore[data.id];

    if (!existingData) {
        existingData = {
            id: data.id,
            name: data.name,
            location: data.location,
            os: data.os,
            cpu: data.cpu,
            mem: data.mem,
            disk: data.disk,
            net: data.net,
            rawTotalNet: { up: data.rawTotalNet ? data.rawTotalNet.up : 0, down: data.rawTotalNet ? data.rawTotalNet.down : 0 },
            totalNet: { up: 0, down: 0 },
            resetDay: 1,
            resetHour: 0,
            resetMinute: 0,
            lastReset: null, // Initialize with null, indicates never reset
            lastUpdated: now,
            online: true,
            expirationDate: null,
            cpuModel: data.cpuModel || null,
            memModel: data.memModel || null,
            diskModel: data.diskModel || null,
            totalTrafficLimit: 0,
            trafficCalculationMode: 'bidirectional',
            systemUptime: data.systemUptime || 0
        };
        console.log(`[${new Date().toISOString()}] New server ${data.id} added.`);
    } else {
        // Ensure core structures exist for older data
        if (!existingData.rawTotalNet) existingData.rawTotalNet = { up: 0, down: 0 };
        if (!existingData.totalNet) existingData.totalNet = { up: 0, down: 0 };
    }

    let upBytesSinceLast = 0;
    let downBytesSinceLast = 0;

    if (data.rawTotalNet.up < existingData.rawTotalNet.up) {
        console.warn(`[${new Date().toISOString()}] Server ${data.id}: Upload raw counter reset detected.`);
        upBytesSinceLast = data.rawTotalNet.up;
    } else {
        upBytesSinceLast = data.rawTotalNet.up - existingData.rawTotalNet.up;
    }

    if (data.rawTotalNet.down < existingData.rawTotalNet.down) {
        console.warn(`[${new Date().toISOString()}] Server ${data.id}: Download raw counter reset detected.`);
        downBytesSinceLast = data.rawTotalNet.down;
    } else {
        downBytesSinceLast = data.rawTotalNet.down - existingData.rawTotalNet.down;
    }

    upBytesSinceLast = Math.max(0, upBytesSinceLast);
    downBytesSinceLast = Math.max(0, downBytesSinceLast);

    existingData.totalNet.up += upBytesSinceLast;
    existingData.totalNet.down += downBytesSinceLast;

    serverDataStore[data.id] = {
        ...existingData,
        name: data.name,
        location: data.location,
        os: data.os,
        cpu: data.cpu,
        mem: data.mem,
        disk: data.disk,
        net: data.net,
        cpuModel: data.cpuModel || existingData.cpuModel,
        memModel: data.memModel || existingData.memModel,
        diskModel: data.diskModel || existingData.diskModel,
        rawTotalNet: { up: data.rawTotalNet.up, down: data.rawTotalNet.down },
        lastUpdated: now,
        online: true,
        systemUptime: data.systemUptime,
    };

    saveData();
    res.status(200).send('Report received.');
});

app.get('/api/servers', (req, res) => {
    const now = Date.now();
    Object.values(serverDataStore).forEach(server => {
        server.online = (now - server.lastUpdated) < 15000; // 15 seconds threshold
    });
    res.json(Object.values(serverDataStore));
});

app.post('/api/servers/:id/settings', (req, res) => {
    const { id } = req.params;
    const { totalNetUp, totalNetDown, resetDay, resetHour, resetMinute, password, expirationDate, totalTrafficLimit, trafficCalculationMode } = req.body;

    if (password !== AGENT_INSTALL_PASSWORD) {
        return res.status(403).send('Incorrect agent installation password.');
    }

    if (serverDataStore[id]) {
        serverDataStore[id].totalNet.up = totalNetUp;
        serverDataStore[id].totalNet.down = totalNetDown;
        serverDataStore[id].resetDay = resetDay;
        serverDataStore[id].resetHour = resetHour;
        serverDataStore[id].resetMinute = resetMinute;
        serverDataStore[id].expirationDate = expirationDate;
        serverDataStore[id].totalTrafficLimit = totalTrafficLimit;
        serverDataStore[id].trafficCalculationMode = trafficCalculationMode;
        saveData();
        res.status(200).send('Settings updated successfully.');
    } else {
        res.status(404).send('Server not found.');
    }
});

app.delete('/api/servers/:id', (req, res) => {
    const { id } = req.params;
    const { password } = req.body;

    if (!password) {
        return res.status(400).send('Password required.');
    }
    if (password !== DELETE_PASSWORD) {
        return res.status(403).send('Incorrect password.');
    }

    if (serverDataStore[id]) {
        delete serverDataStore[id];
        saveData();
        res.status(200).send('Server deleted successfully.');
    } else {
        res.status(404).send('Server not found.');
    }
});

app.post('/api/verify-agent-password', (req, res) => {
    const { password } = req.body;
    if (password === AGENT_INSTALL_PASSWORD) {
        res.status(200).send('Agent installation password correct.');
    } else {
        res.status(403).send('Invalid agent installation password.');
    }
});

/**
 * Traffic reset check function - Runs periodically to reset monthly traffic.
 * This function has been refactored for accuracy and reliability.
 */
function checkAndResetTraffic() {
    // Use 'Asia/Shanghai' timezone for all date calculations.
    const nowInShanghai = new Date(new Date().toLocaleString('en-US', { timeZone: 'Asia/Shanghai' }));
    let changed = false;

    console.log(`[${new Date().toISOString()}] Running periodic traffic reset check. Current Shanghai Time: ${nowInShanghai.toISOString()}`);

    Object.keys(serverDataStore).forEach(id => {
        const server = serverDataStore[id];

        // Ensure we have valid reset settings, otherwise skip.
        if (server.resetDay === undefined || server.resetHour === undefined || server.resetMinute === undefined) {
            return;
        }

        // Determine the last reset date.
        let lastResetDate = new Date(0); // Default to epoch (a long time ago) if never reset.
        if (server.lastReset) {
            // Check for the old 'YYYY-M' format for backward compatibility.
            if (typeof server.lastReset === 'string' && /^\d{4}-\d{1,2}$/.test(server.lastReset)) {
                const parts = server.lastReset.split('-');
                const lastResetYear = parseInt(parts[0], 10);
                const lastResetMonth = parseInt(parts[1], 10) - 1; // 0-indexed month
                // Assume it was reset at the configured time during that month.
                lastResetDate = new Date(lastResetYear, lastResetMonth, server.resetDay, server.resetHour, server.resetMinute, 0);
            }
            // Check for the new ISO string format.
            else if (!isNaN(new Date(server.lastReset).getTime())) {
                lastResetDate = new Date(server.lastReset);
            }
        }

        // Calculate the reset date for the *current* cycle.
        // This is the most recent reset date that *should have* occurred.
        let resetDateThisCycle = new Date(nowInShanghai.getFullYear(), nowInShanghai.getMonth(), server.resetDay, server.resetHour, server.resetMinute, 0);

        // If the current time is before this month's reset date, then the current cycle's target was last month's reset date.
        if (nowInShanghai.getTime() < resetDateThisCycle.getTime()) {
            resetDateThisCycle.setMonth(resetDateThisCycle.getMonth() - 1);
        }

        // A reset is needed if:
        // 1. The current time is past the scheduled reset time for this cycle.
        // 2. The last known reset was performed *before* this cycle's scheduled reset time.
        if (nowInShanghai.getTime() >= resetDateThisCycle.getTime() && lastResetDate.getTime() < resetDateThisCycle.getTime()) {
            console.log(`[${new Date().toISOString()}] RESETTING TRAFFIC for server ${id}. Current Time: ${nowInShanghai.toISOString()}, Scheduled Reset: ${resetDateThisCycle.toISOString()}, Last Reset: ${lastResetDate.toISOString()}`);
            server.totalNet = { up: 0, down: 0 };
            server.lastReset = resetDateThisCycle.toISOString(); // Store the precise reset timestamp.
            changed = true;
        }
    });

    if (changed) {
        console.log(`[${new Date().toISOString()}] Traffic reset complete, saving data...`);
        saveData();
    }
}


// Start the server and the periodic check.
app.listen(PORT, '0.0.0.0', () => {
    console.log(`[${new Date().toISOString()}] Monitor backend server running on http://0.0.0.0:${PORT}`);
    // Check for traffic reset every minute.
    setInterval(checkAndResetTraffic, 1000 * 60);
    // Run the check immediately on startup.
    checkAndResetTraffic();
});
