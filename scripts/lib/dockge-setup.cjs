// Create the first Dockge administrator through Dockge's own setup API.
// Runs inside the Dockge container (node -e <this file>), with the credentials in
// DOCKGE_ADMIN_USER / DOCKGE_ADMIN_PASSWORD (never on the command line).
// Exit codes: 0 created, 3 already initialized, 1 anything else.
const { io } = require("/app/node_modules/socket.io-client");

const username = process.env.DOCKGE_ADMIN_USER;
const password = process.env.DOCKGE_ADMIN_PASSWORD;
if (!username || !password) {
    console.error("DOCKGE_ADMIN_USER and DOCKGE_ADMIN_PASSWORD are required.");
    process.exit(1);
}

const socket = io("http://127.0.0.1:5001", { transports: ["websocket"], reconnection: false, timeout: 10000 });
const fail = (message, code = 1) => {
    console.error(message);
    socket.close();
    process.exit(code);
};
const timer = setTimeout(() => fail("Timed out talking to Dockge."), 20000);

socket.on("connect_error", (error) => fail(`Cannot connect to Dockge: ${error.message}`));
socket.on("connect", () => {
    socket.emit("setup", username, password, (result) => {
        clearTimeout(timer);
        if (result && result.ok) {
            console.log("Dockge administrator created.");
            socket.close();
            process.exit(0);
        }
        const message = (result && result.msg) || "unknown error";
        fail(`Dockge setup: ${message}`, /initialized/i.test(message) ? 3 : 1);
    });
});
