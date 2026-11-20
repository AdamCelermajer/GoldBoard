// Finds your WoW Forever folder, so no personal path is written into the code.
// Order: the GOLDBOARD_WOW environment variable, "wow" in config.local.json (not committed), then the
// usual install places on every drive. The value is the "World of Warcraft" folder (the one holding _forever_).
const fs = require("fs");
const path = require("path");

const FLAVOR = "_forever_";

function candidates() {
  const out = [];
  if (process.env.GOLDBOARD_WOW) out.push(process.env.GOLDBOARD_WOW);
  try {
    const cfg = JSON.parse(fs.readFileSync(path.join(__dirname, "config.local.json"), "utf8"));
    if (cfg.wow) out.push(cfg.wow);
  } catch {}
  for (const drive of "CDEFGH") {
    for (const rel of ["World of Warcraft", "Program Files (x86)\\World of Warcraft", "Program Files\\World of Warcraft",
      "Games\\World of Warcraft", "Blizzard\\World of Warcraft"]) out.push(`${drive}:\\${rel}`);
  }
  return out;
}

let cached;
function forever() {
  if (cached !== undefined) return cached;
  cached = null;
  for (const root of candidates()) {
    const dir = path.join(root, FLAVOR);
    if (fs.existsSync(path.join(dir, "WTF")) || fs.existsSync(path.join(dir, "Interface"))) { cached = dir; break; }
  }
  return cached;
}

// Every account's SavedVariables file for an addon (most people have one account).
function savedVariables(addon) {
  const dir = forever();
  if (!dir) return [];
  const accounts = path.join(dir, "WTF", "Account");
  if (!fs.existsSync(accounts)) return [];
  return fs.readdirSync(accounts)
    .map((a) => path.join(accounts, a, "SavedVariables", `${addon}.lua`))
    .filter((f) => fs.existsSync(f));
}

function addonFolder(addon) {
  const dir = forever();
  const f = dir && path.join(dir, "Interface", "AddOns", addon);
  return f && fs.existsSync(f) ? f : null;
}

module.exports = { forever, savedVariables, addonFolder };
