// TSM price collector for WoW Forever (EU, Alliance auction houses).
// Downloads TSM's free public price files (the only automated access TSM's terms allow),
// keeps every new version as a snapshot, then rebuilds dashboard.html.
//
//   node collect.js            one poll + dashboard (what the scheduled task runs)
//   node collect.js --build    dashboard only, no download
//
// The task starts every 30 min. After 24 h of polling it measures how often TSM really
// refreshes the auction-house files and, once, moves the task to that interval
// (rounded down to a multiple of 30 min), e.g. hourly if TSM updates hourly.
const fs = require("fs");
const path = require("path");
const zlib = require("zlib");
const { execFileSync } = require("child_process");
const { buildDashboard } = require("./dashboard.js");

const ROOT = __dirname;
const DATA = path.join(ROOT, "data");
const SNAP = path.join(DATA, "snapshots");
const POLLS = path.join(DATA, "polls.jsonl");
const STATE = path.join(DATA, "state.json");
const LOCK = path.join(DATA, "collect.lock");
const TASK = "TSM Forever Collector";
const BASE = "https://public-data.tradeskillmaster.com/forever/eu";

// realm files: auction houses (refresh every 3 h); Roleplay-Alliance is the one you play on and comes first.
// region: all of EU (daily)
const SOURCES = [
  { id: "roleplay-alliance", label: "Roleplay - Alliance", url: `${BASE}/realm/roleplay-alliance/items.csv`, kind: "realm" },
  { id: "normal-alliance", label: "Normal - Alliance", url: `${BASE}/realm/normal-alliance/items.csv`, kind: "realm" },
  { id: "eu-region", label: "All of EU", url: `${BASE}/region/items.csv`, kind: "region" },
];
module.exports.SOURCES = SOURCES;
module.exports.paths = { DATA, SNAP, POLLS, STATE };

function readState() {
  try { return JSON.parse(fs.readFileSync(STATE, "utf8")); } catch { return {}; }
}
function writeState(s) { fs.writeFileSync(STATE, JSON.stringify(s, null, 2)); }
function log(msg) {
  const line = `${new Date().toISOString()} ${msg}\n`;
  fs.appendFileSync(path.join(DATA, "collector.log"), line);
  process.stdout.write(line);
}
// "2026-11-17T15:19:04Z" -> file-name safe
const stamp = (iso) => iso.replace(/[:]/g, "-");

async function fetchCsv(url) {
  const res = await fetch(url, { headers: { "User-Agent": "personal-price-collector" }, signal: AbortSignal.timeout(60000) });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  const text = await res.text();
  if (!text.startsWith("itemId,")) throw new Error("not a price file");
  return text;
}
// updatedAt is the last column, the same on every row
function updatedAtOf(csv) {
  const first = (csv.split("\n", 2)[1] || "").trim();
  const v = first.slice(first.lastIndexOf(",") + 1);
  if (!/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/.test(v)) throw new Error("no updatedAt in file");
  return v;
}

async function poll(state) {
  const t = new Date().toISOString();
  for (const src of SOURCES) {
    const entry = { t, source: src.id };
    try {
      const csv = await fetchCsv(src.url);
      const updatedAt = updatedAtOf(csv);
      entry.updatedAt = updatedAt;
      const dir = path.join(SNAP, src.id);
      fs.mkdirSync(dir, { recursive: true });
      const file = path.join(dir, `${stamp(updatedAt)}.csv.gz`);
      entry.changed = !fs.existsSync(file);
      if (entry.changed) fs.writeFileSync(file, zlib.gzipSync(csv));
      log(`${src.id}: TSM data of ${updatedAt}${entry.changed ? " (new, saved)" : " (unchanged)"}`);
    } catch (e) {
      entry.error = String(e.message || e);
      log(`${src.id}: failed: ${entry.error}`);
    }
    fs.appendFileSync(POLLS, JSON.stringify(entry) + "\n");
  }
  state.firstPoll = state.firstPoll || t;
  state.lastPoll = t;
  state.intervalMin = state.intervalMin || 30;
}

// gaps (minutes) between successive TSM refreshes of the realm files, from the file timestamps
function refreshGaps() {
  const gaps = [];
  for (const src of SOURCES.filter((s) => s.kind === "realm")) {
    const dir = path.join(SNAP, src.id);
    if (!fs.existsSync(dir)) continue;
    const times = fs.readdirSync(dir).map((f) => Date.parse(f.replace(".csv.gz", "").replace(/T(\d\d)-(\d\d)-(\d\d)/, "T$1:$2:$3"))).filter(Number.isFinite).sort((a, b) => a - b);
    for (let i = 1; i < times.length; i++) gaps.push((times[i] - times[i - 1]) / 60000);
  }
  return gaps.sort((a, b) => a - b);
}
module.exports.refreshGaps = refreshGaps;

function setTaskInterval(minutes) {
  const ps = `$t = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(${minutes}) -RepetitionInterval (New-TimeSpan -Minutes ${minutes}); Set-ScheduledTask -TaskName '${TASK}' -Trigger $t | Out-Null`;
  execFileSync("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", ps], { stdio: "ignore", windowsHide: true });
}

// once, after a day of 30-min polls: poll as often as TSM actually refreshes
function maybeAdjustInterval(state) {
  if (state.cadence || !state.firstPoll) return;
  if (Date.now() - Date.parse(state.firstPoll) < 24 * 3600 * 1000) return;
  const gaps = refreshGaps();
  if (gaps.length < 3) { log(`cadence: only ${gaps.length} refreshes seen in a day, keeping 30 min`); state.cadence = { decidedAt: new Date().toISOString(), medianMin: null, intervalMin: 30 }; return; }
  const median = gaps[Math.floor(gaps.length / 2)];
  const interval = Math.max(30, Math.floor(median / 30) * 30);
  state.cadence = { decidedAt: new Date().toISOString(), medianMin: Math.round(median), refreshes: gaps.length + 1, intervalMin: interval };
  if (interval !== state.intervalMin) {
    try {
      setTaskInterval(interval);
      state.intervalMin = interval;
      log(`cadence: TSM refreshes about every ${Math.round(median)} min, task now runs every ${interval} min`);
    } catch (e) {
      state.cadence.error = String(e.message || e);
      log(`cadence: could not change the task: ${state.cadence.error}`);
    }
  } else log(`cadence: TSM refreshes about every ${Math.round(median)} min, keeping ${interval} min`);
}

// One collect run at a time (the scheduled task and the dashboard's rebuild after a /reload can meet):
// the later one waits for the lock. A lock whose run is gone, or older than LOCK_STALE, is taken over.
const LOCK_STALE = 10 * 60 * 1000;
const pidAlive = (pid) => { try { process.kill(pid, 0); return true; } catch (e) { return e.code === "EPERM"; } };
function tryLock() {
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      fs.writeFileSync(LOCK, JSON.stringify({ pid: process.pid, t: Date.now() }), { flag: "wx" });
      return true;
    } catch (e) { if (e.code !== "EEXIST") throw e; }
    let held = {}, age = 0;
    try { held = JSON.parse(fs.readFileSync(LOCK, "utf8")); } catch {}
    try { age = Date.now() - fs.statSync(LOCK).mtimeMs; } catch { continue; }   // just released: try again
    // held by a live run; a fresh lock not yet readable is one being written right now
    if (age < LOCK_STALE && (held.pid ? pidAlive(held.pid) : age < 5000)) return false;
    try { fs.unlinkSync(LOCK); } catch {}
  }
  return false;
}
async function lock(waitMs) {
  const until = Date.now() + waitMs;
  while (!tryLock()) {
    if (Date.now() > until) return false;
    await new Promise((r) => setTimeout(r, 1000));
  }
  return true;
}
function unlock() {
  try { if (JSON.parse(fs.readFileSync(LOCK, "utf8")).pid === process.pid) fs.unlinkSync(LOCK); } catch {}
}
module.exports.lock = lock;
module.exports.unlock = unlock;

async function main() {
  fs.mkdirSync(SNAP, { recursive: true });
  if (!(await lock(process.argv.includes("--build") ? 3 * 60 * 1000 : 10 * 60 * 1000))) {
    log("another collect run is still busy: this one is skipped");
    return;
  }
  process.on("exit", unlock);
  try { await run(); } finally { unlock(); }
}
async function run() {
  const state = readState();
  if (!process.argv.includes("--build")) {
    await poll(state);
    maybeAdjustInterval(state);
    writeState(state);
  }
  // what the Gold Board addon recorded in game (buys, sales, gold, your scans), if it's installed
  try { require("./ledger.js").ingest(log); } catch (e) { log(`goldboard: ${e.message}`); }
  const out = buildDashboard(state);
  log(`dashboard: ${out}`);
}
if (require.main === module) main().catch((e) => { log(`fatal: ${e.stack || e}`); process.exitCode = 1; });
