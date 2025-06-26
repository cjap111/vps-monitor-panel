// server.js
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
            // Initialize new fields for precise reset time
            if (serverDataStore[id].resetDay === undefined) {
                serverDataStore[id].resetDay = 1; // Default to 1st day of month
            }
            if (serverDataStore[id].resetHour === undefined) {
                serverDataStore[id].resetHour = 0; // Default to 00:00
            }
            if (serverDataStore[id].resetMinute === undefined) {
                serverDataStore[id].resetMinute = 0; // Default to 00:00
            }
            // If lastReset was an old format string (like "2024-05"), convert it to a timestamp for consistency
            if (typeof serverDataStore[id].lastReset === 'string') {
                const [year, month] = serverDataStore[id].lastReset.split('-').map(Number);
                const prevResetDay = serverDataStore[id].resetDay || 1;
                const prevResetHour = serverDataStore[id].resetHour || 0;
                const prevResetMinute = serverDataStore[id].resetMinute || 0;
                serverDataStore[id].lastReset = new Date(year, month - 1, prevResetDay, prevResetHour, prevResetMinute, 0, 0).getTime();
                console.warn(`[${new Date().toISOString()}] Converted old lastReset string to timestamp for server ${id}.`);
            } else if (serverDataStore[id].lastReset === undefined) {
                // For servers that never had lastReset set, initialize it to the previous month's reset point
                // or current month's if already passed. This prevents immediate reset on startup if data existed.
                const sResetDay = serverDataStore[id].resetDay || 1;
                const sResetHour = serverDataStore[id].resetHour || 0;
                const sResetMinute = serverDataStore[id].resetMinute || 0;

                const now = new Date();
                const currentYear = now.getFullYear();
                const currentMonth = now.getMonth();

                const currentMonthResetDate = new Date(currentYear, currentMonth, sResetDay, sResetHour, sResetMinute, 0, 0);
                const prevMonthResetDate = new Date(currentYear, currentMonth - 1, sResetDay, sResetHour, sResetMinute, 0, 0);

                if (now.getTime() >= currentMonthResetDate.getTime()) {
                    serverDataStore[id].lastReset = currentMonthResetDate.getTime();
                } else {
                    serverDataStore[id].lastReset = prevMonthResetDate.getTime();
                }
                console.warn(`[${new Date().toISOString()}] Initialized missing lastReset for server ${id} on startup to: ${new Date(serverDataStore[id].lastReset).toISOString()}.`);
            }
            // Ensure uptimeSeconds is initialized
            if (serverDataStore[id].uptimeSeconds === undefined) {
                serverDataStore[id].uptimeSeconds = 0; // Default to 0
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
    const currentYear = new Date().getFullYear();
    const currentMonth = new Date().getMonth(); // 0-indexed
    let existingData = serverDataStore[data.id];

    // Initialize server data if it's a new server or core data structures are missing
    if (!existingData) {
        // Calculate initial lastReset to ensure first reset happens correctly
        const resetDayForNewServer = data.resetDay !== undefined ? data.resetDay : 1;
        const resetHourForNewServer = data.resetHour !== undefined ? data.resetHour : 0;
        const resetMinuteForNewServer = data.resetMinute !== undefined ? data.resetMinute : 0;

        // Determine the initial lastReset based on current time and desired reset point
        // If current time is past the reset point for the current month, set lastReset to this month's reset point.
        // Otherwise, set it to the previous month's reset point to ensure a reset happens this month.
        const currentMonthResetDate = new Date(currentYear, currentMonth, resetDayForNewServer, resetHourForNewServer, resetMinuteForNewServer, 0, 0);
        const prevMonthResetDate = new Date(currentYear, currentMonth - 1, resetDayForNewServer, resetHourForNewServer, resetMinuteForNewServer, 0, 0);

        let initialLastReset;
        if (now >= currentMonthResetDate.getTime()) {
            initialLastReset = currentMonthResetDate.getTime();
        } else {
            initialLastReset = prevMonthResetDate.getTime();
        }

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
            resetDay: resetDayForNewServer, // Default reset day
            resetHour: resetHourForNewServer, // Default reset hour (00:00)
            resetMinute: resetMinuteForNewServer, // Default reset minute (00:00)
            lastReset: initialLastReset, // Use the calculated initial lastReset
            uptimeSeconds: data.uptimeSeconds || 0, // Store agent's reported uptime
            lastUpdated: now,
            online: true,
            expirationDate: null,
            cpuModel: data.cpuModel || null,
            memModel: data.memModel || null,
            diskModel: data.diskModel || null,
            totalTrafficLimit: 0, // Initialize new field for total traffic limit
            trafficCalculationMode: 'bidirectional' // Default to bidirectional
        };
        console.log(`[${new Date().toISOString()}] New server ${data.id} added with initial lastReset: ${new Date(initialLastReset).toISOString()}.`);
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
        if (existingData.resetDay === undefined) {
            existingData.resetDay = 1;
        }
        if (existingData.resetHour === undefined) {
            existingData.resetHour = 0;
        }
        if (existingData.resetMinute === undefined) {
            existingData.resetMinute = 0;
        }
        // If lastReset was an old format string or undefined, convert it to a timestamp for consistency
        if (typeof existingData.lastReset === 'string') {
             const [year, month] = existingData.lastReset.split('-').map(Number);
            const prevResetDay = existingData.resetDay || 1;
            const prevResetHour = existingData.resetHour || 0;
            const prevResetMinute = existingData.resetMinute || 0;
            existingData.lastReset = new Date(year, month - 1, prevResetDay, prevResetHour, prevResetMinute, 0, 0).getTime();
            console.warn(`[${new Date().toISOString()}] Converted old lastReset string to timestamp for server ${data.id}.`);
        } else if (existingData.lastReset === undefined) {
            // For servers that never had lastReset set, initialize it to the previous month's reset point
            // or current month's if already passed. This prevents immediate reset on startup if data existed.
            const sResetDay = existingData.resetDay || 1;
            const sResetHour = existingData.resetHour || 0;
            const sResetMinute = existingData.resetMinute || 0;

            const now = new Date();
            const currentYear = now.getFullYear();
            const currentMonth = now.getMonth();

            const currentMonthResetDate = new Date(currentYear, currentMonth, sResetDay, sResetHour, sResetMinute, 0, 0);
            const prevMonthResetDate = new Date(currentYear, currentMonth - 1, sResetDay, sResetHour, sResetMinute, 0, 0);

            if (now.getTime() >= currentMonthResetDate.getTime()) {
                existingData.lastReset = currentMonthResetDate.getTime();
            } else {
                existingData.lastReset = prevMonthResetDate.getTime();
            }
            console.warn(`[${new Date().toISOString()}] Initialized missing lastReset for server ${data.id} during report to: ${new Date(existingData.lastReset).toISOString()}.`);
        }
        // Ensure uptimeSeconds is present for existing servers
        if (existingData.uptimeSeconds === undefined) {
            existingData.uptimeSeconds = 0;
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
        uptimeSeconds: data.uptimeSeconds || existingData.uptimeSeconds, // Update with agent's reported uptime
        lastUpdated: now, // Always update lastUpdated timestamp
        online: true, // Mark as online
        // totalTrafficLimit, trafficCalculationMode, resetDay, resetHour, resetMinute are preserved from existingData or initialized above
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
    // Destructure new fields: totalTrafficLimit and trafficCalculationMode
    const { totalNetUp, totalNetDown, resetDay, resetHour, resetMinute, password, expirationDate, totalTrafficLimit, trafficCalculationMode } = req.body;

    console.log(`[${new Date().toISOString()}] Received settings update for server ID: ${id}.`);
    console.log(`[${new Date().toISOString()}] New settings: totalTrafficLimit=${totalTrafficLimit}, trafficCalculationMode=${trafficCalculationMode}, resetDay=${resetDay}, resetHour=${resetHour}, resetMinute=${resetMinute}.`);


    // Validate agent installation password
    if (!password || password !== AGENT_INSTALL_PASSWORD) {
        console.error(`[${new Date().toISOString()}] Invalid agent installation password for server ${id} settings.`);
        return res.status(403).send('Incorrect agent installation password.');
    }

    if (serverDataStore[id]) {
        const server = serverDataStore[id];
        const oldTotalNetUp = server.totalNet.up;
        const oldTotalNetDown = server.totalNet.down;
        const oldResetDay = server.resetDay;
        const oldResetHour = server.resetHour;
        const oldResetMinute = server.resetMinute;

        server.totalNet.up = totalNetUp;
        server.totalNet.down = totalNetDown;
        server.resetDay = resetDay;
        server.resetHour = resetHour;
        server.resetMinute = resetMinute;
        server.expirationDate = expirationDate;
        server.totalTrafficLimit = totalTrafficLimit;
        server.trafficCalculationMode = trafficCalculationMode;

        // Determine if traffic was manually reset (totalNet changed) or if reset settings changed
        const trafficManuallyReset = (oldTotalNetUp !== totalNetUp || oldTotalNetDown !== totalNetDown);
        // FIX: Corrected typo from 'oldResetHour !== oldResetHour' to 'oldResetHour !== resetHour'
        const resetSettingsChanged = (oldResetDay !== resetDay || oldResetHour !== resetHour || Math.abs(oldResetMinute - resetMinute) > 1); // 1 minute tolerance for minute change

        // If traffic was manually reset or reset settings changed, re-evaluate lastReset.
        // This ensures the 'lastReset' timestamp accurately reflects the point from which
        // the next traffic reset cycle should be calculated.
        if (trafficManuallyReset || resetSettingsChanged) {
            console.log(`[${new Date().toISOString()}] Server ${id}: Traffic manually reset or reset settings changed. Re-evaluating lastReset.`);
            const now = new Date();
            const currentYear = now.getFullYear();
            const currentMonth = now.getMonth();

            // Calculate the exact target reset date for the current month based on NEW settings
            const currentMonthNewResetDate = new Date(currentYear, currentMonth, resetDay, resetHour, resetMinute, 0, 0);
            
            // Calculate the exact target reset date for the previous month based on NEW settings
            const prevMonthNewResetDate = new Date(currentYear, currentMonth - 1, resetDay, resetHour, resetMinute, 0, 0);

            // Determine the appropriate lastReset timestamp:
            // If current time is past or at the new reset point for THIS month,
            // then the "last reset" is effectively THIS month's reset point.
            if (now.getTime() >= currentMonthNewResetDate.getTime()) {
                server.lastReset = currentMonthNewResetDate.getTime();
                console.log(`[${new Date().toISOString()}] Server ${id}: lastReset set to current month's new reset time (past): ${new Date(server.lastReset).toISOString()}.`);
            } else {
                // If current time is BEFORE this month's reset point,
                // then the "last reset" should be the PREVIOUS month's reset point,
                // so that the current month's reset triggers when its time comes.
                server.lastReset = prevMonthNewResetDate.getTime();
                console.log(`[${new Date().toISOString()}] Server ${id}: lastReset set to previous month's new reset time (future current month reset): ${new Date(server.lastReset).toISOString()}.`);
            }
        }

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

    console.log(`[${new Date().toISOString()}] Received delete request for server ID: ${id}.`);

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

// Traffic reset check function - Runs hourly to reset monthly traffic
function checkAndResetTraffic() {
    const now = new Date();
    const currentYear = now.getFullYear();
    const currentMonth = now.getMonth(); // 0-indexed
    const currentDay = now.getDate();
    const currentHour = now.getHours();
    const currentMinute = now.getMinutes();

    let changed = false;

    console.log(`[${new Date().toISOString()}] Running hourly traffic reset check... Current time: ${String(currentYear).padStart(4, '0')}-${String(currentMonth + 1).padStart(2, '0')}-${String(currentDay).padStart(2, '0')} ${String(currentHour).padStart(2, '0')}:${String(currentMinute).padStart(2, '0')}`);

    Object.keys(serverDataStore).forEach(id => {
        const server = serverDataStore[id];

        // Default values for reset if not set
        const resetDay = server.resetDay !== undefined ? server.resetDay : 1;
        const resetHour = server.resetHour !== undefined ? server.resetHour : 0;
        const resetMinute = server.resetMinute !== undefined ? server.resetMinute : 0;

        // Construct the target reset date for the current month based on configured settings
        const targetResetDate = new Date(currentYear, currentMonth, resetDay, resetHour, resetMinute, 0, 0);
        
        // Construct the target reset date for the *previous* month
        const prevMonthTargetResetDate = new Date(currentYear, currentMonth - 1, resetDay, resetHour, resetMinute, 0, 0);

        const lastResetTimestamp = typeof server.lastReset === 'number' ? server.lastReset : 0;

        console.log(`[${new Date().toISOString()}] Server ${id} - Detail for reset check:`);
        console.log(`  Current Time (ms): ${now.getTime()} (${now.toISOString()})`);
        console.log(`  Target Reset Date (ms): ${targetResetDate.getTime()} (${targetResetDate.toISOString()})`);
        console.log(`  Previous Month Target Reset Date (ms): ${prevMonthTargetResetDate.getTime()} (${prevMonthTargetResetDate.toISOString()})`);
        console.log(`  Last Reset Timestamp (ms): ${lastResetTimestamp} (${new Date(lastResetTimestamp).toISOString()})`);
        console.log(`  Condition 1 (now >= target): ${now.getTime() >= targetResetDate.getTime()}`);
        console.log(`  Condition 2 (lastReset < target): ${lastResetTimestamp < targetResetDate.getTime()}`);
        console.log(`  Condition 3 (lastReset < prevMonthTarget): ${lastResetTimestamp < prevMonthTargetResetDate.getTime()}`);


        let shouldReset = false;
        
        // Condition for resetting:
        // A reset is due if the current time is at or past the target reset point for this month,
        // AND the server's 'lastReset' timestamp indicates that it was reset *before* this current month's target reset point.
        // This covers normal monthly resets and cases where 'lastReset' was very old.
        if (now.getTime() >= targetResetDate.getTime() && lastResetTimestamp < targetResetDate.getTime()) {
            shouldReset = true;
            console.log(`[${new Date().toISOString()}] Server ${id}: Reset condition met (Normal monthly reset or very old lastReset).`);
        } 
        // Additional condition for edge cases, e.g., if the reset settings were changed recently
        // and 'lastReset' was manually pushed to a future date, but now 'now' has passed the actual reset point for this month.
        // Or if the server was offline for an extended period, and its lastReset timestamp is still far in the past,
        // even if the current month's targetResetDate has been surpassed.
        // This makes sure that if the last reset was before the previous month's reset point, and we are now past the current month's reset point, it triggers.
        else if (lastResetTimestamp < prevMonthTargetResetDate.getTime() && now.getTime() >= targetResetDate.getTime()) {
            shouldReset = true;
            console.log(`[${new Date().toISOString()}] Server ${id}: Reset triggered by very old lastReset and current time past target.`);
        }

        console.log(`  Final shouldReset: ${shouldReset}`);

        if (shouldReset) {
            console.log(`[${new Date().toISOString()}] Resetting traffic for server ${id}. New totalNet will be 0.`);
            server.totalNet = { up: 0, down: 0 };
            server.lastReset = targetResetDate.getTime(); // Update lastReset to the exact reset point for this cycle
            changed = true;
        } else {
            console.log(`[${new Date().toISOString()}] Server ${id}: No traffic reset needed yet.`);
        }
    });

    if (changed) {
        console.log(`[${new Date().toISOString()}] Traffic reset complete, saving data...`);
        saveData();
    }
}

// Start the server and set up hourly traffic reset check
app.listen(PORT, '0.0.0.0', () => {
    console.log(`[${new Date().toISOString()}] Monitor backend server running on http://0.0.0.0:${PORT}`);
    // Check for traffic reset hourly
    setInterval(checkAndResetTraffic, 1000 * 60 * 60); // Check every hour
    // Run check immediately on startup
    checkAndResetTraffic();
});
