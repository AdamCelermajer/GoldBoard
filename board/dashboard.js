// Builds dashboard.html from the saved TSM snapshots (one self-contained page, open it in a browser).
const fs = require("fs");
const path = require("path");
const zlib = require("zlib");

const ROOT = __dirname;
const SNAP = path.join(ROOT, "data", "snapshots");
const POLLS = path.join(ROOT, "data", "polls.jsonl");
const OUT = path.join(ROOT, "dashboard.html");
const HISTORY_DAYS = 30;  // charted history; older snapshots stay on disk

// CSV with quoted fields ("" = a quote inside one)
function parseCsv(text) {
  const rows = [];
  let row = [], field = "", i = 0, q = false;
  for (; i < text.length; i++) {
    const c = text[i];
    if (q) {
      if (c === '"') { if (text[i + 1] === '"') { field += '"'; i++; } else q = false; }
      else field += c;
    } else if (c === '"') q = true;
    else if (c === ",") { row.push(field); field = ""; }
    else if (c === "\n") { row.push(field.replace(/\r$/, "")); rows.push(row); row = []; field = ""; }
    else field += c;
  }
  if (field || row.length) { row.push(field); rows.push(row); }
  const header = rows.shift();
  return rows.filter((r) => r.length === header.length).map((r) => Object.fromEntries(header.map((h, k) => [h, r[k]])));
}
module.exports.parseCsv = parseCsv;

const num = (v) => (v === "" || v == null ? null : Number(v));
const fileTime = (f) => Date.parse(f.replace(".csv.gz", "").replace(/T(\d\d)-(\d\d)-(\d\d)/, "T$1:$2:$3"));

function loadSource(id) {
  const dir = path.join(SNAP, id);
  if (!fs.existsSync(dir)) return [];
  return fs.readdirSync(dir).filter((f) => f.endsWith(".csv.gz"))
    .map((f) => ({ f, t: fileTime(f) })).filter((x) => Number.isFinite(x.t)).sort((a, b) => a.t - b.t)
    .map((x) => ({ t: x.t, rows: parseCsv(zlib.gunzipSync(fs.readFileSync(path.join(dir, x.f))).toString("utf8")) }));
}

function buildDashboard(state) {
  const { SOURCES, refreshGaps } = require("./collect.js");
  const names = {};
  const realms = {};
  let region = { t: null, items: {} };
  const cutoff = Date.now() - HISTORY_DAYS * 86400000;

  for (const src of SOURCES) {
    const snaps = loadSource(src.id);
    if (!snaps.length) continue;
    if (src.kind === "region") {
      const last = snaps[snaps.length - 1];
      region.t = last.t;
      for (const r of last.rows) {
        names[r.itemId] = r.name;
        region.items[r.itemId] = [num(r.marketValue), num(r.historical), num(r.avgSalePrice), num(r.saleRate), num(r.soldPerDay)];
      }
      continue;
    }
    // per item: latest values + minBuyout/marketValue at every snapshot of the last HISTORY_DAYS
    const recent = snaps.filter((s) => s.t >= cutoff);
    const times = recent.map((s) => Math.round(s.t / 60000));  // minutes since epoch
    const latest = {}, minB = {}, mkt = {};
    recent.forEach((s, k) => {
      for (const r of s.rows) {
        const id = r.itemId;
        names[id] = r.name;
        if (!minB[id]) { minB[id] = new Array(recent.length).fill(null); mkt[id] = new Array(recent.length).fill(null); }
        minB[id][k] = num(r.minBuyout);
        mkt[id][k] = num(r.marketValue);
      }
    });
    const last = snaps[snaps.length - 1];
    for (const r of last.rows) latest[r.itemId] = [num(r.marketValue), num(r.minBuyout), num(r.recent), num(r.historical)];
    realms[src.id] = { label: src.label, t: last.t, snapshots: snaps.length, times, latest, minB, mkt };
  }

  // collector health
  const polls = fs.existsSync(POLLS) ? fs.readFileSync(POLLS, "utf8").trim().split("\n").filter(Boolean).map((l) => JSON.parse(l)) : [];
  const pollTimes = [...new Set(polls.map((p) => p.t))];
  const errors = polls.filter((p) => p.error).slice(-5);
  const gaps = refreshGaps();
  const status = {
    firstPoll: state.firstPoll || null, lastPoll: state.lastPoll || null, polls: pollTimes.length,
    intervalMin: state.intervalMin || 30, cadence: state.cadence || null,
    gaps: { count: gaps.length, min: gaps[0] ?? null, median: gaps.length ? gaps[Math.floor(gaps.length / 2)] : null, max: gaps[gaps.length - 1] ?? null },
    errors, sources: SOURCES.map((s) => ({ id: s.id, label: s.label, kind: s.kind })),
  };

  // what you did in game (Gold Board addon): ledger, gold, holdings, your own auction house scans
  const L = require("./ledger.js");
  const game = L.load();
  for (const [name, id] of Object.entries(game.names)) if (!names[id]) names[id] = name;
  const myScans = scanSeries(L.loadScans(cutoff), realms, region, game.ledger);

  // the signals the addon shows in tooltips and beside the auction house
  const signals = buildSignals(realms, region, game.ledger);
  try {
    const file = L.writeSignals(signals);
    status.signals = file ? { written: Date.now(), items: Object.values(signals).reduce((n, s) => n + Object.keys(s.items).length, 0) } : null;
  } catch (e) { status.signals = { error: e.message }; }

  // Auctionator's daily history per item as [minute, low, high, available] (its days start at day0)
  const ac = game.auctionator || { items: {} };
  const auctionator = { ah: ac.ah || null, items: {} };
  if (ac.day0) for (const [id, days] of Object.entries(ac.items)) {
    auctionator.items[id] = Object.entries(days).map(([d, v]) => [Math.round((Number(d) * 86400 + ac.day0) / 60), ...v])
      .sort((a, b) => a[0] - b[0]);
  }
  const data = { generatedAt: Date.now(), status, names, region, realms, ledger: game.ledger, gold: game.gold,
                 holdings: game.holdings, myScans, auctionator };
  const json = JSON.stringify(data).replace(/</g, "\\u003c");
  const html = fs.readFileSync(path.join(ROOT, "dashboard.template.html"), "utf8").replace("/*__DATA__*/null", json);
  fs.writeFileSync(OUT, html);
  return OUT;
}
module.exports.buildDashboard = buildDashboard;

const AH_CUT = 0.05;
// The same reading of TSM's numbers as the dashboard: what it realistically sells for is the lowest of its
// market value here, its 60-day price and its real EU sale price; buy below leaves 15% after the auction cut.
function sellFor(latest, reg) {
  const [market, , , hist] = latest || [];
  const saleAvg = reg ? reg[2] : null;
  const refs = [market, hist, saleAvg].filter((v) => v > 0);
  return refs.length ? Math.min(...refs) : null;
}

function buildSignals(realms, region, ledger) {
  const traded = new Set(ledger.map((e) => String(e.itemID)).filter((x) => x !== "undefined"));
  const out = {};
  for (const [ah, R] of Object.entries(realms)) {
    const items = {};
    // trend: cheapest listing now vs about a day earlier (8 TSM updates back at one every 3 hours)
    const back = Math.max(0, R.times.length - 9);
    for (const [id, latest] of Object.entries(R.latest)) {
      const reg = region.items[id];
      const sold = reg ? reg[4] : null;
      if (!((sold || 0) >= 0.5 || traded.has(id))) continue;
      const sell = sellFor(latest, reg);
      if (!sell) continue;
      const minBuy = latest[1] || 0;
      const then = R.minB[id] ? R.minB[id][back] : null;
      const trend = then > 0 && minBuy > 0 ? Math.round((minBuy / then - 1) * 100) : "";
      // timing only for items that trade often enough for an hourly pattern to mean something
      const h = (sold || 0) >= 3 ? hourTiming(R.minB[id], R.times) : null;
      items[id] = [Math.round(sell), Math.round(sell * (1 - AH_CUT) * 0.85), latest[0] || 0, minBuy, trend,
                   sold == null ? "" : Math.round(sold * 10) / 10, h ? h.buyHour : "", h ? h.sellHour : "",
                   h ? h.spread : ""].join(":");
    }
    out[ah] = { t: R.t, label: R.label, items };
  }
  return out;
}

// When an item is usually cheapest (buy) and dearest (sell), in local hours, from its cheapest listing at
// each TSM update compared with its own median; spread = how much dearer the dear hour is, in %.
// Only once there's enough history (8+ updates covering 5+ different hours) and a real difference.
function hourTiming(series, times) {
  if (!series) return null;
  const vals = series.filter((v) => v > 0).sort((a, b) => a - b);
  if (vals.length < 8) return null;
  const med = vals[vals.length >> 1];
  const sum = {}, n = {};
  series.forEach((v, k) => {
    if (!(v > 0)) return;
    const h = new Date(times[k] * 60000).getHours();
    sum[h] = (sum[h] || 0) + Math.log(v / med);
    n[h] = (n[h] || 0) + 1;
  });
  const hours = Object.keys(n).map(Number);
  if (hours.length < 5) return null;
  let lo = hours[0], hi = hours[0];
  for (const h of hours) {
    if (sum[h] / n[h] < sum[lo] / n[lo]) lo = h;
    if (sum[h] / n[h] > sum[hi] / n[hi]) hi = h;
  }
  const spread = Math.round((Math.exp(sum[hi] / n[hi] - sum[lo] / n[lo]) - 1) * 100);
  return spread >= 3 && spread <= 60 ? { buyHour: lo, sellHour: hi, spread } : null;   // above 60% it's a stray listing, not a pattern
}

// Your own Auctionator scans per auction house: times, and for liquid or traded items a sparse series
// "k:min:qty,k:min:qty" (k = index into times) to keep the page small.
function scanSeries(scans, realms, region, ledger) {
  const traded = new Set(ledger.map((e) => String(e.itemID)));
  const out = {};
  for (const s of scans) {
    const ah = s.ah;
    const o = out[ah] || (out[ah] = { times: [], items: {} });
    const k = o.times.length;
    o.times.push(Math.round(s.t / 60000));
    for (const [id, v] of Object.entries(s.items)) {
      const reg = region.items[id];
      if (!(((reg && reg[4]) || 0) >= 2 || traded.has(id))) continue;
      o.items[id] = (o.items[id] ? o.items[id] + "," : "") + `${k}:${v[0]}:${v[2]}`;
    }
  }
  return out;
}
