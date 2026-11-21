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

// A character saved while the game answered an empty realm ("Name-", or "Name-?") is the same character as
// "Name-Realm": merged into it, so its gold counts once. Only when exactly one realm is known (else which
// realm it was can't be told). The addon does the same to its own data from 2.3.3 on.
const REALMLESS = /^([^-]*)-\??$/;
function mergeRealmless(gold, ledger) {
  const realms = new Set();
  for (const g of Object.values(gold)) if (g && typeof g.realm === "string" && g.realm && g.realm !== "?") realms.add(g.realm);
  if (realms.size !== 1) return;
  const realm = [...realms][0];
  for (const key of Object.keys(gold)) {
    const m = key.match(REALMLESS);
    if (!m) continue;
    const from = gold[key], target = `${m[1]}-${realm}`, into = gold[target];
    delete gold[key];
    if (!into) { gold[target] = Object.assign(from, { realm }); continue; }
    const seen = new Set(into.samples.map((x) => `${x[0]}:${x[1]}`));
    for (const x of from.samples || []) if (!seen.has(`${x[0]}:${x[1]}`)) { seen.add(`${x[0]}:${x[1]}`); into.samples.push(x); }
    into.samples.sort((a, b) => a[0] - b[0]);
    for (const k of ["class", "faction", "ah"]) if (into[k] == null) into[k] = from[k];
  }
  for (const e of ledger) { const m = typeof e.char === "string" && e.char.match(REALMLESS); if (m) e.char = `${m[1]}-${realm}`; }
}

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
      if (!s || !Number.isSafeInteger(s.t) || s.t <= 0 || typeof s.data !== "string" || !s.data) continue;
      // the file name only ever holds a number and [a-z0-9_-] (no path, nothing Windows refuses)
      const ah = String(s.ah || "unknown").toLowerCase().replace(/[^a-z0-9_-]/g, "_");
      const f = path.join(SCANS, `${s.t}-${ah}.txt.gz`);
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
  mergeRealmless(gold, merged);
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

// SignalsData.lua for the installed addon: per auction house, "sell:buyBelow:market:minBuy:trend:soldPerDay:..."
// Everything that goes into the Lua text is checked first: auction house ids are [a-z0-9_-], item ids are
// digits, every value field is a finite number or empty, and the labels are written as Lua strings.
const luaString = (v) => `"${String(v).replace(/[\\"]/g, (c) => `\\${c}`).replace(/[\x00-\x1f\x7f]/g, (c) => `\\${String(c.charCodeAt(0)).padStart(3, "0")}`)}"`;
const AH_ID = /^[a-z0-9_-]+$/i;
const ITEM_ID = /^\d+$/;
const FIELD = /^-?\d+(\.\d+)?$/;
function validValue(v) {
  if (typeof v !== "string" || v.length > 200) return false;
  return v.split(":").every((part) => part === "" || (FIELD.test(part) && Number.isFinite(Number(part))));
}
function signalsLua(signals, log = () => {}) {
  const ahs = Object.entries(signals).filter(([ah, s]) => {
    const ok = AH_ID.test(ah) && s && Number.isFinite(s.t) && s.items && typeof s.items === "object";
    if (!ok) log(`signals: skipped auction house ${JSON.stringify(ah)} (bad id or data)`);
    return ok;
  });
  const lines = ["-- Written by the Gold Board dashboard. Do not edit: it is replaced after every TSM update.",
    `GoldBoardSignalsData = { generated = ${Math.floor(Date.now() / 1000)}, tsm = {`];
  for (const [ah, s] of ahs) lines.push(`  [${luaString(ah)}] = ${Math.floor(s.t / 1000)},`);
  lines.push("}, labels = {");
  for (const [ah, s] of ahs) lines.push(`  [${luaString(ah)}] = ${luaString(s.label == null ? ah : s.label)},`);
  lines.push("}, ah = {");
  let skipped = 0;
  for (const [ah, s] of ahs) {
    lines.push(`  [${luaString(ah)}] = {`);
    for (const [id, v] of Object.entries(s.items)) {
      if (!ITEM_ID.test(id) || !validValue(v)) { skipped++; continue; }
      lines.push(`    [${id}] = "${v}",`);
    }
    lines.push("  },");
  }
  lines.push("} }", "");
  if (skipped) log(`signals: skipped ${skipped} item(s) with a bad id or value`);
  return lines.join("\n");
}

// Written to a temporary file next to it, then renamed over it: the game never finds it half written.
// A rename that is refused (the file held open elsewhere) is retried a few times, then reported, and the
// old file stays as it was.
function replaceFile(file, text) {
  const tmp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, text);
  for (let i = 0; ; i++) {
    try { fs.renameSync(tmp, file); return; } catch (e) {
      if (i >= 4 || !["EPERM", "EBUSY", "EACCES"].includes(e.code)) {
        try { fs.unlinkSync(tmp); } catch {}
        throw e;
      }
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 200);
    }
  }
}

function writeSignals(signals, log = () => {}) {
  const dir = wow.addonFolder("GoldBoard");
  if (!dir) return null;
  const file = path.join(dir, "SignalsData.lua");
  replaceFile(file, signalsLua(signals, log));
  return file;
}

module.exports = { ingest, load, loadScans, writeSignals, mergeRealmless, signalsLua };
