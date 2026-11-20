// Takes in what the Gold Board addon recorded in game (GoldBoardDB) and keeps it in data/goldboard/:
//   ledger.json  every buy, sale, post, cancel and expiry, merged by id (the addon's own data is never changed)
//   gold.json    gold over time per character
//   scans/       your Auctionator full scans (the addon keeps only the newest 30; these are kept for good)
// Then writes the signals the addon shows in game (SignalsData.lua in the installed addon folder).
const fs = require("fs");
const path = require("path");
const zlib = require("zlib");
const wow = require("./wow.js");
const { parseSavedVariables } = require("./luadata.js");

const DIR = path.join(__dirname, "data", "goldboard");
const SCANS = path.join(DIR, "scans");
const LEDGER = path.join(DIR, "ledger.json");
const GOLD = path.join(DIR, "gold.json");

const readJson = (f, d) => { try { return JSON.parse(fs.readFileSync(f, "utf8")); } catch { return d; } };

function ingest(log = () => {}) {
  fs.mkdirSync(SCANS, { recursive: true });
  const files = wow.savedVariables("GoldBoard");
  if (!files.length) return { found: false };
  const ledger = readJson(LEDGER, []);
  const byId = new Map(ledger.map((e) => [e.id, e]));
  const gold = readJson(GOLD, {});
  let newEntries = 0, newScans = 0;
  const holdings = {}, names = {};
  const auctionator = readJson(path.join(DIR, "auctionator.json"), { items: {} });
  for (const file of files) {
    let db;
    try { db = parseSavedVariables(fs.readFileSync(file, "utf8")).GoldBoardDB; } catch (e) { log(`goldboard: could not read the addon's saved data: ${e.message}`); continue; }
    if (!db) continue;
    for (const e of db.ledger || []) {
      if (!e || !e.id) continue;
      const prev = byId.get(e.id);
      if (!prev) newEntries++;
      byId.set(e.id, Object.assign(prev || {}, e));   // later saves can add a flag (e.g. "mailed")
    }
    for (const [char, c] of Object.entries(db.chars || {})) {
      const g = gold[char] || { samples: [] };
      Object.assign(g, { class: c.class, realm: c.realm, faction: c.faction, ah: c.ah });
      const have = new Set(g.samples.map((s) => s[0]));
      for (const s of c.gold || []) if (Array.isArray(s) && !have.has(s[0])) g.samples.push([s[0], s[1]]);
      g.samples.sort((a, b) => a[0] - b[0]);
      gold[char] = g;
    }
    for (const s of db.scans || []) {
      if (!s || !s.t || !s.data) continue;
      const f = path.join(SCANS, `${s.t}-${s.ah || "unknown"}.txt.gz`);
      if (fs.existsSync(f)) continue;
      fs.writeFileSync(f, zlib.gzipSync(s.data));
      newScans++;
    }
    Object.assign(holdings, db.holdings || {});
    // Auctionator's daily lows and highs, merged by day (Auctionator itself only keeps recent days)
    const a = db.auctionator;
    if (a && a.items && a.day0) {
      auctionator.day0 = a.day0;
      auctionator.ah = a.ah || auctionator.ah;
      auctionator.t = Math.max(auctionator.t || 0, a.t || 0);
      for (const [id, s] of Object.entries(a.items)) {
        const days = auctionator.items[id] || (auctionator.items[id] = {});
        for (const part of String(s).split(",")) {
          const [day, low, high, avail] = part.split(":");
          if (day && Number(low) > 0) days[day] = [Number(low), Number(high) || Number(low), avail === "" ? null : Number(avail)];
        }
      }
    }
    Object.assign(names, db.names || {});
  }
  const merged = [...byId.values()].sort((a, b) => (a.t || 0) - (b.t || 0));
  fs.writeFileSync(LEDGER, JSON.stringify(merged));
  fs.writeFileSync(GOLD, JSON.stringify(gold));
  fs.writeFileSync(path.join(DIR, "holdings.json"), JSON.stringify(holdings));
  fs.writeFileSync(path.join(DIR, "names.json"), JSON.stringify(names));
  fs.writeFileSync(path.join(DIR, "auctionator.json"), JSON.stringify(auctionator));
  if (newEntries || newScans) log(`goldboard: ${newEntries} new ledger entries, ${newScans} new scans from the game`);
  return { found: true, newEntries, newScans };
}

// Your own scans: [{ t, ah, items: { id: [min, p25, qty, auctions, sellers] } }], oldest first
function loadScans(sinceMs) {
  if (!fs.existsSync(SCANS)) return [];
  return fs.readdirSync(SCANS).filter((f) => f.endsWith(".txt.gz")).map((f) => {
    const m = f.match(/^(\d+)-(.+)\.txt\.gz$/);
    return m && { t: Number(m[1]) * 1000, ah: m[2], f };
  }).filter((s) => s && s.t >= sinceMs).sort((a, b) => a.t - b.t).map((s) => {
    const items = {};
    for (const part of zlib.gunzipSync(fs.readFileSync(path.join(SCANS, s.f))).toString().split(";")) {
      const [id, ...v] = part.split(":").map(Number);
      if (id) items[id] = v;
    }
    return { t: s.t, ah: s.ah, items };
  });
}

const load = () => ({
  ledger: readJson(LEDGER, []),
  gold: readJson(GOLD, {}),
  holdings: readJson(path.join(DIR, "holdings.json"), {}),
  names: readJson(path.join(DIR, "names.json"), {}),
  auctionator: readJson(path.join(DIR, "auctionator.json"), { items: {} }),
});

// SignalsData.lua for the installed addon: per auction house, "sell:buyBelow:market:minBuy:trend:soldPerDay"
function writeSignals(signals, log = () => {}) {
  const dir = wow.addonFolder("GoldBoard");
  if (!dir) return null;
  const lines = ["-- Written by the Gold Board dashboard. Do not edit: it is replaced after every TSM update.",
    `GoldBoardSignalsData = { generated = ${Math.floor(Date.now() / 1000)}, tsm = {`];
  for (const [ah, s] of Object.entries(signals)) lines.push(`  ["${ah}"] = ${Math.floor(s.t / 1000)},`);
  lines.push("}, labels = {");
  for (const [ah, s] of Object.entries(signals)) lines.push(`  ["${ah}"] = ${JSON.stringify(s.label)},`);
  lines.push("}, ah = {");
  for (const [ah, s] of Object.entries(signals)) {
    lines.push(`  ["${ah}"] = {`);
    for (const [id, v] of Object.entries(s.items)) lines.push(`    [${id}] = "${v}",`);
    lines.push("  },");
  }
  lines.push("} }", "");
  const file = path.join(dir, "SignalsData.lua");
  fs.writeFileSync(file, lines.join("\n"));
  return file;
}

module.exports = { ingest, load, loadScans, writeSignals };
