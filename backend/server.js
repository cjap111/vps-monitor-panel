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
        // Ensure old data has rawTotalNet and totalNet initialized correctly on load if missing
        Object.keys(serverDataStore).forEach(id => {
            if (!serverDataStore[id].rawTotalNet) {
                serverDataStore[id].rawTotalNet = { up: 0, down: 0 };
                console.warn(`[${new Date().toISOString()}] Initialized missing rawTotalNet for server ${id} on startup.`);
            }
            if (!serverDataStore[id].totalNet) {
                serverDataStore[id].totalNet = { up: 0, down: 0 };
                console.warn(`[${new Date().toISOString()}] Initialized missing totalNet for server ${id} on startup.`);
            }
            // Initialize new fields for traffic limit and calculation mode
            if (serverDataStore[id].totalTrafficLimit === undefined) {
                serverDataStore[id].totalTrafficLimit = 0; // Default to 0, meaning no limit set initially
            }
            if (serverDataStore[id].trafficCalculationMode === undefined) {
                serverDataStore[id].trafficCalculationMode = 'bidirectional'; // Default to bidirectional
            }
            // Initialize systemUptime if missing
            if (serverDataStore[id].systemUptime === undefined) {
                serverDataStore[id].systemUptime = 0; // Default to 0 seconds
            }
            // New: Initialize resetHour and resetMinute if missing
            if (serverDataStore[id].resetHour === undefined) {
                serverDataStore[id].resetHour = 0; // Default to 0 (midnight)
                console.warn(`[${new Date().toISOString()}] Initialized missing resetHour for server ${id} on startup.`);
            }
            if (serverDataStore[id].resetMinute === undefined) { // New field for minute
                serverDataStore[id].resetMinute = 0; // Default to 0 minutes
                console.warn(`[${new Date().toISOString()}] Initialized missing resetMinute for server ${id} on startup.`);
            }
            // Initialize lastReset to a valid format if it's missing or old
            if (!serverDataStore[id].lastReset || !/^\d{4}-\d{1,2}$/.test(serverDataStore[id].lastReset)) {
                const now = new Date();
                serverDataStore[id].lastReset = `${now.getFullYear()}-${now.getMonth() + 1}`;
                console.warn(`[${new Date().toISOString()}] Initialized/Corrected lastReset format for server ${id} on startup.`);
            }
        });
        saveData(); // Save updated structure if any initialization happened
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
app.use(express.urlencoded({ extended: true, limit: '1mb' })); // Add urlencoded middleware for robustness

// --- Routes ---

// A simple root route to check if the backend is alive
app.get('/', (req, res) => {
    console.log(`[${new Date().toISOString()}] Root path accessed.`);
    res.status(200).send('Monitor Backend is running!');
});

// POST /api/report - Receive monitoring data from agents
app.post('/api/report', (req, res) => {
    const data = req.body;
    console.log(`[${new Date().toISOString()}] Received report from server ID: ${data.id}`);

    if (!data.id) {
        console.error(`[${new Date().toISOString()}] Error: Server ID is required for report.`);
        return res.status(400).send('Server ID is required.');
    }

    const now = Date.now();
    let existingData = serverDataStore[data.id];

    // Initialize server data if it's a new server or core data structures are missing
    if (!existingData) {
        existingData = {
            id: data.id,
            name: data.name,
            location: data.location,
            os: data.os,
            cpu: data.cpu,
            mem: data.mem,
            disk: data.disk,
            net: data.net, // Current network speed
            rawTotalNet: { up: data.rawTotalNet ? data.rawTotalNet.up : 0, down: data.rawTotalNet ? data.rawTotalNet.down : 0 }, // Initialize with current raw data, handle potential undefined
            totalNet: { up: 0, down: 0 }, // Initialize accumulated total traffic
            resetDay: 1, // Default reset day
            resetHour: 0, // Default reset hour (midnight)
            resetMinute: 0, // Default reset minute (0 minutes)
            lastReset: `${new Date().getFullYear()}-${new Date().getMonth() + 1}`,
            lastUpdated: now,
            online: true,
            expirationDate: null,
            cpuModel: data.cpuModel || null,
            memModel: data.memModel || null,
            diskModel: data.diskModel || null,
            totalTrafficLimit: 0, // Initialize new field for total traffic limit
            trafficCalculationMode: 'bidirectional', // Initialize new field for calculation mode
            systemUptime: data.systemUptime || 0 // New field for system uptime in seconds
        };
        console.log(`[${new Date().toISOString()}] New server ${data.id} added.`);
    } else {
        // Ensure existing data has rawTotalNet and totalNet for calculations
        if (!existingData.rawTotalNet) {
            existingData.rawTotalNet = { up: 0, down: 0 };
        }
        if (!existingData.totalNet) {
            existingData.totalNet = { up: 0, down: 0 };
        }
        // Ensure new fields are present for existing servers loaded from file
        if (existingData.totalTrafficLimit === undefined) {
            existingData.totalTrafficLimit = 0;
        }
        if (existingData.trafficCalculationMode === undefined) {
            existingData.trafficCalculationMode = 'bidirectional';
        }
        if (existingData.systemUptime === undefined) {
            existingData.systemUptime = 0;
        }
        // New: Ensure resetHour and resetMinute are present for existing servers
        if (existingData.resetHour === undefined) {
            existingData.resetHour = 0;
        }
        if (existingData.resetMinute === undefined) {
            existingData.resetMinute = 0;
        }
        // Ensure lastReset is present and correctly formatted
        if (!existingData.lastReset || !/^\d{4}-\d{1,2}$/.test(existingData.lastReset)) {
            const now = new Date();
            existingData.lastReset = `${now.getFullYear()}-${now.getMonth() + 1}`;
            console.warn(`[${new Date().toISOString()}] Corrected lastReset format for existing server ${id}.`);
        }
    }

    let upBytesSinceLast = 0;
    let downBytesSinceLast = 0;

    // Log raw counters before calculation for debugging
    console.log(`[${new Date().toISOString()}] Server ${data.id} - Raw Traffic Incoming: Up=${data.rawTotalNet.up}, Down=${data.rawTotalNet.down}`);
    console.log(`[${new Date().toISOString()}] Server ${data.id} - Raw Traffic Existing: Up=${existingData.rawTotalNet.up}, Down=${existingData.rawTotalNet.down}`);

    // Traffic calculation logic for accumulated data:
    // If current raw counter is less than last known raw counter, assume agent reset/reboot.
    // In this case, the current raw counter represents the traffic since the reboot,
    // so we add the current raw value as the increment for this specific interval.
    if (data.rawTotalNet.up < existingData.rawTotalNet.up) {
        console.warn(`[${new Date().toISOString()}] Server ${data.id}: Upload raw counter reset detected. Adding current reported raw value as increment.`);
        upBytesSinceLast = data.rawTotalNet.up;
    } else {
        upBytesSinceLast = data.rawTotalNet.up - existingData.rawTotalNet.up;
    }

    if (data.rawTotalNet.down < existingData.rawTotalNet.down) {
        console.warn(`[${new Date().toISOString()}] Server ${data.id}: Download raw counter reset detected. Adding current reported raw value as increment.`);
        downBytesSinceLast = data.rawTotalNet.down;
    } else {
        downBytesSinceLast = data.rawTotalNet.down - existingData.rawTotalNet.down;
    }

    // Ensure increments are non-negative (traffic should not decrease)
    upBytesSinceLast = Math.max(0, upBytesSinceLast);
    downBytesSinceLast = Math.max(0, downBytesSinceLast);

    // Add increments to total traffic
    existingData.totalNet.up += upBytesSinceLast;
    existingData.totalNet.down += downBytesSinceLast;

    // Log increments and new total for debugging
    console.log(`[${new Date().toISOString()}] Server ${data.id} - Increments: Up=${upBytesSinceLast}, Down=${downBytesSinceLast}`);
    console.log(`[${new Date().toISOString()}] Server ${data.id} - New Total Traffic: Up=${existingData.totalNet.up}, Down=${existingData.totalNet.down}`);


    // Update serverDataStore with all latest information
    serverDataStore[data.id] = {
        ...existingData, // Preserve existing accumulated data and settings
        id: data.id, // Explicitly set ID
        name: data.name, // Update these fields from agent data
        location: data.location,
        os: data.os,
        cpu: data.cpu,
        mem: data.mem,
        disk: data.disk,
        net: data.net, // Current network speed
        cpuModel: data.cpuModel || existingData.cpuModel, // Update if new, preserve if not
        memModel: data.memModel || existingData.memModel, // Update if new, preserve if not
        diskModel: data.diskModel || existingData.diskModel, // Update if new, preserve if not
        totalNet: existingData.totalNet, // Explicitly keep the updated totalNet
        rawTotalNet: { up: data.rawTotalNet.up, down: data.rawTotalNet.down }, // Crucial: Update rawTotalNet for the next comparison
        lastUpdated: now, // Always update lastUpdated timestamp
        online: true, // Mark as online
        systemUptime: data.systemUptime, // Store the new system uptime
        // totalTrafficLimit, trafficCalculationMode, resetHour, and resetMinute are preserved from existingData or initialized above
    };

    saveData(); // Save data to file
    res.status(200).send('Report received.');
});

// GET /api/servers - Get all server data for the frontend
app.get('/api/servers', (req, res) => {
    console.log(`[${new Date().toISOString()}] Request received for server list.`);
    const now = Date.now();
    // Check online status for all servers - adjusted to 15 seconds threshold for 1-second reporting for better tolerance
    Object.values(serverDataStore).forEach(server => {
        // If no update for more than 15 seconds, consider offline
        server.online = (now - server.lastUpdated) < 15000;
    });
    res.json(Object.values(serverDataStore));
});

// POST /api/servers/:id/settings - Update server settings (requires agent installation password)
app.post('/api/servers/:id/settings', (req, res) => {
    const { id } = req.params;
    // Destructure new fields: totalTrafficLimit, trafficCalculationMode, resetHour, and resetMinute
    const { totalNetUp, totalNetDown, resetDay, resetHour, resetMinute, password, expirationDate, totalTrafficLimit, trafficCalculationMode } = req.body;

    console.log(`[${new Date().toISOString()}] Received settings update for server ID: ${id}`);
    console.log(`[${new Date().toISOString()}] New settings: totalTrafficLimit=${totalTrafficLimit}, trafficCalculationMode=${trafficCalculationMode}, resetDay=${resetDay}, resetHour=${resetHour}, Minute=${resetMinute}`);


    // Validate agent installation password
    if (!password || password !== AGENT_INSTALL_PASSWORD) {
        console.error(`[${new Date().toISOString()}] Invalid agent installation password for server ${id} settings.`);
        return res.status(403).send('Incorrect agent installation password.');
    }

    if (serverDataStore[id]) {
        serverDataStore[id].totalNet.up = totalNetUp;
        serverDataStore[id].totalNet.down = totalNetDown;
        serverDataStore[id].resetDay = resetDay;
        serverDataStore[id].resetHour = resetHour; // Save the new reset hour
        serverDataStore[id].resetMinute = resetMinute; // Save the new reset minute
        serverDataStore[id].expirationDate = expirationDate; // Save expiration date
        // Save new traffic limit and calculation mode
        serverDataStore[id].totalTrafficLimit = totalTrafficLimit;
        serverDataStore[id].trafficCalculationMode = trafficCalculationMode;

        // Note: cpuModel, memModel, diskModel, rawTotalNet, and systemUptime are not updated via settings route, they are only updated by agent reports.
        saveData(); // Save data
        console.log(`[${new Date().toISOString()}] Server ${id} settings updated successfully.`);
        res.status(200).send('Settings updated successfully.');
    } else {
        console.error(`[${new Date().toISOString()}] Server ${id} not found for settings update.`);
        res.status(404).send('Server not found.');
    }
});

// DELETE /api/servers/:id - Delete a server (requires delete password)
app.delete('/api/servers/:id', (req, res) => {
    const { id } = req.params;
    const { password } = req.body;

    console.log(`[${new Date().toISOString()}] Received delete request for server ID: ${id}`);

    if (!password) {
        console.error(`[${new Date().toISOString()}] Password required for deleting server ${id}.`);
        return res.status(400).send('Password required.');
    }
    if (password !== DELETE_PASSWORD) {
        console.error(`[${new Date().toISOString()}] Incorrect password for deleting server ${id}.`);
        return res.status(403).send('Incorrect password.');
    }

    if (serverDataStore[id]) {
        delete serverDataStore[id];
        saveData(); // Save data
        console.log(`[${new Date().toISOString()}] Server ${id} deleted.`);
        res.status(200).send('Server deleted successfully.');
    } else {
        console.error(`[${new Date().toISOString()}] Server ${id} not found for deletion.`);
        res.status(404).send('Server not found.');
    }
});

// POST /api/verify-agent-password - Verify the agent installation password
app.post('/api/verify-agent-password', (req, res) => {
    const { password } = req.body;
    console.log(`[${new Date().toISOString()}] Received agent password verification request.`);
    if (password && password === AGENT_INSTALL_PASSWORD) {
        res.status(200).send('Agent installation password correct.');
        console.log(`[${new Date().toISOString()}] Agent installation password verified successfully.`);
    } else {
        res.status(403).send('Invalid agent installation password.');
        console.warn(`[${new Date().toISOString()}] Invalid agent installation password provided.`);
    }
});

// Traffic reset check function - Runs every minute to reset monthly traffic
function checkAndResetTraffic() {
    // Get current date and time in Shanghai timezone
    // IMPORTANT: Ensure the backend server's system timezone is set to Asia/Shanghai for reliability.
    const nowInShanghai = new Date().toLocaleString('en-US', { timeZone: 'Asia/Shanghai' });
    const currentShanghaiDate = new Date(nowInShanghai);
    const currentYearShanghai = currentShanghaiDate.getFullYear();
    const currentMonthShanghai = currentShanghaiDate.getMonth(); // 0-indexed month
    const currentDayShanghai = currentShanghaiDate.getDate();
    const currentHourShanghai = currentShanghaiDate.getHours();
    const currentMinuteShanghai = currentShanghaiDate.getMinutes();
    const currentMonthYearShanghai = `${currentYearShanghai}-${currentMonthShanghai + 1}`;

    let changed = false;

    console.log(`[${new Date().toISOString()}] Running minute-by-minute traffic reset check for Shanghai time (${currentDayShanghai}日 ${currentHourShanghai}点${currentMinuteShanghai}分, Month: ${currentMonthShanghai + 1})...`);

    Object.keys(serverDataStore).forEach(id => {
        const server = serverDataStore[id];

        // Ensure server.lastReset is correctly parsed or initialized for comparison
        let lastResetMonth = -1;
        let lastResetYear = -1;
        if (server.lastReset && typeof server.lastReset === 'string') {
            const parts = server.lastReset.split('-');
            if (parts.length === 2) {
                lastResetYear = parseInt(parts[0]);
                lastResetMonth = parseInt(parts[1]) - 1; // Convert to 0-indexed month
            }
        }

        // Construct the target reset date object for the current month
        // Use current year and month for the target reset date's month, so it correctly falls within the current billing cycle
        const targetResetDate = new Date(currentYearShanghai,
                                         currentMonthShanghai, // Use current month for target date
                                         server.resetDay,
                                         server.resetHour,
                                         server.resetMinute,
                                         0); // Seconds to 0 for precise comparison


        // Condition 1: Check if the current time has passed or is exactly the configured reset time for the current month.
        // This makes the reset more robust against slight timing inaccuracies of setInterval.
        const hasPassedOrIsResetTime = currentShanghaiDate.getTime() >= targetResetDate.getTime();

        // Condition 2: Check if the reset hasn't happened yet for the current month/year.
        // This is crucial for monthly reset logic.
        const notYetResetForCurrentMonth = !(lastResetYear === currentYearShanghai && lastResetMonth === currentMonthShanghai);

        // Additional robustness for cases where the server might have been offline during the exact reset time
        // If current month is after the last reset month (or current year is after last reset year), it should reset.
        const monthHasChangedSinceLastReset = (currentYearShanghai > lastResetYear) ||
                                             (currentYearShanghai === lastResetYear && currentMonthShanghai > lastResetMonth);

        console.log(`[${new Date().toISOString()}] Server ${id} - Configured: Day ${server.resetDay}, Hour ${server.resetHour}, Minute ${server.resetMinute}.`);
        console.log(`[${new Date().toISOString()}] Server ${id} - Current Shanghai: Year ${currentYearShanghai}, Month ${currentMonthShanghai + 1}, Day ${currentDayShanghai}, Hour ${currentHourShanghai}, Minute ${currentMinuteShanghai}.`);
        console.log(`[${new Date().toISOString()}] Server ${id} - Last Reset: ${server.lastReset || 'N/A'}.`);
        console.log(`[${new Date().toISOString()}] Server ${id} - Has passed reset time (${targetResetDate.toISOString()}): ${hasPassedOrIsResetTime}.`);
        console.log(`[${new Date().toISOString()}] Server ${id} - Not yet reset for current month: ${notYetResetForCurrentMonth}.`);
        console.log(`[${new Date().toISOString()}] Server ${id} - Month has changed since last reset: ${monthHasChangedSinceLastReset}.`);


        // Main reset logic
        if (notYetResetForCurrentMonth && (hasPassedOrIsResetTime || monthHasChangedSinceLastReset)) {
            console.log(`[${new Date().toISOString()}] Resetting traffic for server ${id} as per configured time...`);
            server.totalNet = { up: 0, down: 0 };
            server.lastReset = currentMonthYearShanghai;
            changed = true;
        } else {
            console.log(`[${new Date().toISOString()}] Server ${id}: No reset needed.`);
        }
    });

    if (changed) {
        console.log(`[${new Date().toISOString()}] Traffic reset complete, saving data...`);
        saveData();
    }
}

// Start the server and set up minute-by-minute traffic reset check
app.listen(PORT, '0.0.0.0', () => {
    console.log(`[${new Date().toISOString()}] Monitor backend server running on http://0.0.0.0:${PORT}`);
    // Check for traffic reset every minute
    setInterval(checkAndResetTraffic, 1000 * 60); // Run every minute
    // Run check immediately on startup
    checkAndResetTraffic();
});
