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

// POST /api/report
app.post('/api/report', (req, res) => {
    const data = req.body;
    if (!data.id) {
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
            // Record last reset month in YYYY-M format
            lastReset: `${now_date.getFullYear()}-${now_date.getMonth() + 1}`, 
            startTime: now,
            lastUpdated: now,
            online: true,
            expirationDate: null // Added: Initialize expiration date for new server
        };
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
            lastUpdated: now,
            online: true
        };
    }

    saveData(); // Save data
    res.status(200).send('Report received.');
});

// GET /api/servers
app.get('/api/servers', (req, res) => {
    const now = Date.now();
    // Check online status for all servers
    Object.values(serverDataStore).forEach(server => {
        // If no update for more than 30 seconds, consider offline
        server.online = (now - server.lastUpdated) < 30000; 
    });
    res.json(Object.values(serverDataStore));
});

// POST /api/servers/:id/settings - Now requires agent installation password and expiration date
app.post('/api/servers/:id/settings', (req, res) => {
    const { id } = req.params;
    const { totalNetUp, totalNetDown, resetDay, password, expirationDate } = req.body; // Add password and expirationDate
    
    // Validate agent installation password
    if (!password || password !== AGENT_INSTALL_PASSWORD) {
        return res.status(403).send('Incorrect agent installation password.');
    }

    if (serverDataStore[id]) {
        serverDataStore[id].totalNet.up = totalNetUp;
        serverDataStore[id].totalNet.down = totalNetDown;
        serverDataStore[id].resetDay = resetDay;
        serverDataStore[id].expirationDate = expirationDate; // Save expiration date
        saveData(); // Save data
        res.status(200).send('Settings updated successfully.');
    } else {
        res.status(404).send('Server not found.');
    }
});

// DELETE /api/servers/:id
app.delete('/api/servers/:id', (req, res) => {
    const { id } = req.params;
    const { password } = req.body;

    if (!password) return res.status(400).send('Password required.');
    if (password !== DELETE_PASSWORD) return res.status(403).send('Incorrect password.');

    if (serverDataStore[id]) {
        delete serverDataStore[id];
        saveData(); // Save data
        console.log(`Server ${id} deleted.`);
        res.status(200).send('Server deleted successfully.');
    } else {
        res.status(404).send('Server not found.');
    }
});

// POST /api/verify-agent-password
app.post('/api/verify-agent-password', (req, res) => {
    const { password } = req.body;
    if (password && password === AGENT_INSTALL_PASSWORD) {
        res.status(200).send('Agent installation password correct.');
    } else {
        res.status(403).send('Invalid agent installation password.');
    }
});

// Traffic reset check function
function checkAndResetTraffic() {
    const now = new Date();
    const currentDay = now.getDate();
    // Use YYYY-M format
    const currentMonthYear = `${now.getFullYear()}-${now.getMonth() + 1}`;
    let changed = false;

    console.log(`[${new Date().toISOString()}] Running daily traffic reset check...`);

    Object.keys(serverDataStore).forEach(id => {
        const server = serverDataStore[id];
        // Check if reset day is reached and not yet reset for the current month
        if (server.resetDay === currentDay && server.lastReset !== currentMonthYear) {
            console.log(`Resetting traffic for server ${id}...`);
            server.totalNet = { up: 0, down: 0 };
            server.lastReset = currentMonthYear;
            changed = true;
        }
    });

    if (changed) {
        console.log("Traffic reset complete, saving data...");
        saveData();
    }
}

// Listen on all available network interfaces
app.listen(PORT, '0.0.0.0', () => { 
    console.log(`Monitor backend server running on http://0.0.0.0:${PORT}`); 
    // Check for traffic reset hourly
    setInterval(checkAndResetTraffic, 1000 * 60 * 60); 
    // Run check immediately on startup
    checkAndResetTraffic();
});
