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
    console.log(`[${new Date().toISOString()}] Received report from server ID: ${data.id}`); // Added log for incoming reports
    
    if (!data.id) {
        console.error(`[${new Date().toISOString()}] Error: Server ID is required for report.`); // Added error log
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
            lastReset: `${new Date().getFullYear()}-${new Date().getMonth() + 1}`,
            startTime: now,
            lastUpdated: now,
            online: true,
            expirationDate: null,
            cpuModel: data.cpuModel || null,
            memModel: data.memModel || null,
            diskModel: data.diskModel || null
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
        online: true // Mark as online
    };

    saveData(); // Save data to file
    res.status(200).send('Report received.');
});

// GET /api/servers - Get all server data for the frontend
app.get('/api/servers', (req, res) => {
    console.log(`[${new Date().toISOString()}] Request received for server list.`); // Added log for server list requests
    const now = Date.now();
    // Check online status for all servers
    Object.values(serverDataStore).forEach(server => {
        // If no update for more than 30 seconds, consider offline
        server.online = (now - server.lastUpdated) < 30000; 
    });
    res.json(Object.values(serverDataStore));
});

// POST /api/servers/:id/settings - Update server settings (requires agent installation password)
app.post('/api/servers/:id/settings', (req, res) => {
    const { id } = req.params;
    const { totalNetUp, totalNetDown, resetDay, password, expirationDate } = req.body; 
    
    console.log(`[${new Date().toISOString()}] Received settings update for server ID: ${id}`); // Added log for settings updates

    // Validate agent installation password
    if (!password || password !== AGENT_INSTALL_PASSWORD) {
        console.error(`[${new Date().toISOString()}] Invalid agent installation password for server ${id} settings.`); // Added error log
        return res.status(403).send('Incorrect agent installation password.');
    }

    if (serverDataStore[id]) {
        serverDataStore[id].totalNet.up = totalNetUp;
        serverDataStore[id].totalNet.down = totalNetDown;
        serverDataStore[id].resetDay = resetDay;
        serverDataStore[id].expirationDate = expirationDate; // Save expiration date
        // Note: cpuModel, memModel, diskModel, rawTotalNet are not updated via settings route, they are only updated by agent reports.
        saveData(); // Save data
        console.log(`[${new Date().toISOString()}] Server ${id} settings updated successfully.`); // Log success
        res.status(200).send('Settings updated successfully.');
    } else {
        console.error(`[${new Date().toISOString()}] Server ${id} not found for settings update.`); // Added error log
        res.status(404).send('Server not found.');
    }
});

// DELETE /api/servers/:id - Delete a server (requires delete password)
app.delete('/api/servers/:id', (req, res) => {
    const { id } = req.params;
    const { password } = req.body;

    console.log(`[${new Date().toISOString()}] Received delete request for server ID: ${id}`); // Added log for delete requests

    if (!password) {
        console.error(`[${new Date().toISOString()}] Password required for deleting server ${id}.`); // Added error log
        return res.status(400).send('Password required.');
    }
    if (password !== DELETE_PASSWORD) {
        console.error(`[${new Date().toISOString()}] Incorrect password for deleting server ${id}.`); // Added error log
        return res.status(403).send('Incorrect password.');
    }

    if (serverDataStore[id]) {
        delete serverDataStore[id];
        saveData(); // Save data
        console.log(`[${new Date().toISOString()}] Server ${id} deleted.`); // Log success
        res.status(200).send('Server deleted successfully.');
    } else {
        console.error(`[${new Date().toISOString()}] Server ${id} not found for deletion.`); // Added error log
        res.status(404).send('Server not found.');
    }
});

// POST /api/verify-agent-password - Verify the agent installation password
app.post('/api/verify-agent-password', (req, res) => {
    const { password } = req.body;
    console.log(`[${new Date().toISOString()}] Received agent password verification request.`); // Added log
    if (password && password === AGENT_INSTALL_PASSWORD) {
        res.status(200).send('Agent installation password correct.');
        console.log(`[${new Date().toISOString()}] Agent installation password verified successfully.`); // Log success
    } else {
        res.status(403).send('Invalid agent installation password.');
        console.warn(`[${new Date().toISOString()}] Invalid agent installation password provided.`); // Log warning
    }
});

// Traffic reset check function - Runs hourly to reset monthly traffic
function checkAndResetTraffic() {
    const now = new Date();
    const currentDay = now.getDate();
    // Use `YYYY-M` format
    const currentMonthYear = `${now.getFullYear()}-${now.getMonth() + 1}`;
    let changed = false;

    console.log(`[${new Date().toISOString()}] Running daily traffic reset check...`);

    Object.keys(serverDataStore).forEach(id => {
        const server = serverDataStore[id];
        // Check if reset day is reached and not yet reset for the current month
        if (server.resetDay === currentDay && server.lastReset !== currentMonthYear) {
            console.log(`[${new Date().toISOString()}] Resetting traffic for server ${id}...`);
            server.totalNet = { up: 0, down: 0 };
            server.lastReset = currentMonthYear;
            changed = true;
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
    setInterval(checkAndResetTraffic, 1000 * 60 * 60); 
    // Run check immediately on startup
    checkAndResetTraffic();
});
