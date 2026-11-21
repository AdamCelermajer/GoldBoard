// Gold Board: serves the dashboard on http://localhost:8787, opens it in your browser and shows the
// collector's activity live. Collecting itself is done by the "TSM Forever Collector" scheduled task,
// so it keeps going when this window is closed. Start with "Gold Board.cmd".
const http = require("http"), fs = require("fs"), path = require("path");
const { exec } = require("child_process");

const PORT = 8787;
const URL = `http://localhost:${PORT}`;
const PAGE = path.join(__dirname, "dashboard.html");
const LOG = path.join(__dirname, "data", "collector.log");
const openBrowser = () => exec(`start "" "${URL}"`);

const server = http.createServer((req, res) => {
  if (req.url === "/version") {  // the page checks this and reloads itself when new data is built
    let v = "0";
    try { v = String(fs.statSync(PAGE).mtimeMs); } catch {}
    res.setHeader("Content-Type", "text/plain");
    res.setHeader("Cache-Control", "no-store");
    return res.end(v);
  }
  res.setHeader("Content-Type", "text/html; charset=utf-8");
  res.setHeader("Cache-Control", "no-store");
  fs.createReadStream(PAGE).on("error", () => res.end("dashboard.html missing: run node collect.js")).pipe(res);
});

server.on("error", (e) => {
  if (e.code === "EADDRINUSE") {  // already running in another window: just open the page
    console.log(`Gold Board is already running: opening ${URL}`);
    openBrowser();
    setTimeout(() => process.exit(0), 1500);
  } else throw e;
});

server.listen(PORT, "127.0.0.1", () => {   // this computer only, not the network
  console.log("Forever Gold Board");
  console.log(`  dashboard: ${URL}  (reloads itself when new prices arrive)`);
  console.log(`  collecting: scheduled task "TSM Forever Collector", runs even with this window closed`);
  console.log("  close this window to stop the web page only\n");
  console.log("Recent collector activity:");
  let size = 0;
  try {
    const text = fs.readFileSync(LOG, "utf8");
    size = Buffer.byteLength(text);
    text.trim().split("\n").slice(-8).forEach((l) => console.log("  " + l));
  } catch { console.log("  (no activity yet)"); }
  // print new collector lines as the scheduled task writes them
  fs.watchFile(LOG, { interval: 5000 }, (cur) => {
    if (cur.size <= size) { size = cur.size; return; }
    const fd = fs.openSync(LOG, "r");
    const buf = Buffer.alloc(cur.size - size);
    fs.readSync(fd, buf, 0, buf.length, size);
    fs.closeSync(fd);
    size = cur.size;
    buf.toString("utf8").trim().split("\n").forEach((l) => console.log("  " + l));
  });
  watchGame();
  openBrowser();
});

// When the game saves the Gold Board addon's data (a /reload or logout), rebuild the dashboard at once
// so the Ledger shows your latest buys and sales without waiting for the next TSM check.
function watchGame() {
  const wow = require("./wow.js");
  const { execFile } = require("child_process");
  const seen = {};
  // one rebuild at a time: a save during a rebuild is picked up by one more rebuild right after it
  let building = false, again = false;
  const rebuild = () => {
    if (building) { again = true; return; }
    building = true;
    execFile(process.execPath, [path.join(__dirname, "collect.js"), "--build"], { cwd: __dirname, windowsHide: true }, (err) => {
      building = false;
      if (err) console.log("  rebuild failed: " + err.message);
      if (again) { again = false; rebuild(); }
    });
  };
  const check = () => {
    for (const f of wow.savedVariables("GoldBoard")) {
      let m = 0;
      try { m = fs.statSync(f).mtimeMs; } catch {}
      if (seen[f] === undefined) { seen[f] = m; continue; }
      if (m !== seen[f]) {
        seen[f] = m;
        console.log(`  ${new Date().toISOString()} game data saved: updating the Ledger`);
        rebuild();
      }
    }
  };
  check();
  setInterval(check, 15000);
  console.log(wow.forever() ? "  watching the game's Gold Board data for /reload and logout" : "  WoW Forever folder not found: set GOLDBOARD_WOW or config.local.json (see README)");
}
