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
    console.log(`[${new Date().toISOString()}] Received report from server ID: ${req.body.id}`); // Added log for incoming reports
    const data = req.body;
    if (!data.id) {
        console.error(`[${new Date().toISOString()}] Error: Server ID is required for report.`); // Added error log
        return res.status(400).send('Server ID is required.');
    }

    const now = Date.now();
    const existingData = serverDataStore[data.id];

    if (!existingData) {
        // First report for a new server
        const now_date = new Date();
        serverDataStore[data.id] = {
            ...data,
            totalNet: { up: 0, down: 0 },
            resetDay: 1,
            // Record last reset month in `YYYY-M` format
            lastReset: `${now_date.getFullYear()}-${now_date.getMonth() + 1}`, 
            startTime: now,
            lastUpdated: now,
            online: true,
            expirationDate: null, // Initialize expiration date for new server
            cpuModel: data.cpuModel || null, // Initialize cpuModel for new server
            memModel: data.memModel || null, // Initialize memModel for new server
            diskModel: data.diskModel || null // Initialize diskModel for new server
        };
        console.log(`[${new Date().toISOString()}] New server ${data.id} added.`); // Log new server addition
    } else {
        // Update data for existing server
        let upBytesSinceLast = 0;
        let downBytesSinceLast = 0;
        
        // Robustness check: ensure rawTotalNet exists and values are increasing (prevents agent reboot resetting count)
        if (existingData.rawTotalNet && data.rawTotalNet.up >= existingData.rawTotalNet.up) {
            upBytesSinceLast = data.rawTotalNet.up - existingData.rawTotalNet.up;
        }
        if (existingData.rawTotalNet && data.rawTotalNet.down >= existingData.rawTotalNet.down) {
            downBytesSinceLast = data.rawTotalNet.down - existingData.rawTotalNet.down;
        }
        
        existingData.totalNet.up += upBytesSinceLast;
        existingData.totalNet.down += downBytesSinceLast;

        // Merge new and old data
        serverDataStore[data.id] = {
            ...existingData, // Preserve old settings like totalNet, resetDay, expirationDate etc.
            ...data,         // Overwrite with latest dynamic data from agent report
            totalNet: existingData.totalNet, // Ensure totalNet is not overwritten
            expirationDate: existingData.expirationDate, // Ensure expirationDate is not overwritten by agent data
            cpuModel: data.cpuModel || existingData.cpuModel, // Ensure cpuModel is updated if provided, otherwise preserved
            memModel: data.memModel || existingData.memModel, // Ensure memModel is updated if provided, otherwise preserved
            diskModel: data.diskModel || existingData.diskModel, // Ensure diskModel is updated if provided, otherwise preserved
            lastUpdated: now,
            online: true
        };
        console.log(`[${new Date().toISOString()}] Server ${data.id} updated.`); // Log server update
    }

    saveData(); // Save data
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
    const { totalNetUp, totalNetDown, resetDay, password, expirationDate } = req.body; // Add password and expirationDate
    
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
        // Note: cpuModel, memModel, diskModel are not updated via settings route, they are only updated by agent reports.
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
