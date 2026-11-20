-- Gold Board: the in-game half of the Gold Board dashboard.
--
-- The game can't talk to anything outside it, so the two halves meet through files:
--   * this addon saves GoldBoardDB (gold over time, your auction house buys, sales, posts, expiries,
--     and copies of Auctionator's full scans); the dashboard reads it after a /reload or logout.
--   * the dashboard writes Signals.lua (buy below / sell at, trends) into this folder; the addon
--     reads it at login and /reload and shows it in tooltips and next to the auction house.
-- Nothing here buys, posts or clicks for you.

local ADDON, GB = ...
_G.GoldBoard = GB

GB.version = "2.0.0"
GB.DEFAULT_AH = "roleplay-alliance"   -- the TSM auction house id (ruleset-faction) prices come from

local GOLD_SAMPLE_SEC = 300   -- at most one gold sample per character every 5 minutes (the newest replaces it)

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

function GB.Print(msg) print("|cffe6bb52Gold Board|r: " .. msg) end

-- Values can be "secret" in Forever while restrictions are active: treat them as unknown.
function GB.Clean(v)
  if v ~= nil and issecretvalue and issecretvalue(v) then return nil end
  return v
end

function GB.Money(c)
  c = GB.Clean(c)
  if not c then return "?" end
  local neg = c < 0
  c = math.floor(math.abs(c) + 0.5)
  local g, s, cc = math.floor(c / 10000), math.floor(c / 100) % 100, c % 100
  local out
  if g > 0 then out = string.format("|cffe6bb52%dg|r |cffc9d2d6%ds|r", g, s)
  elseif s > 0 then out = string.format("|cffc9d2d6%ds|r |cffd08a55%dc|r", s, cc)
  else out = string.format("|cffd08a55%dc|r", cc) end
  return (neg and "-" or "") .. out
end

function GB.ItemIDFromLink(link)
  return link and tonumber(link:match("item:(%d+)")) or nil
end

-- Item name -> id, learned from every item the addon sees (sold-auction mails only carry the name).
function GB.LearnName(name, id)
  if name and id then GB.db.names[name] = id end
end
function GB.IDFromName(name)
  if not name then return nil end
  local id = GB.db.names[name]
  if id then return id end
  local instant = C_Item and C_Item.GetItemInfoInstant and C_Item.GetItemInfoInstant(name)
  if instant then GB.db.names[name] = instant end
  return instant
end

-- "First Last" for Forever characters (UnitName returns both parts), with the realm.
function GB.Character()
  local first, last = UnitName("player")
  local name = (last and last ~= "") and (first .. " " .. last) or first
  return name .. "-" .. (GetRealmName() or "?")
end

-- Which TSM auction house this character's prices come from (set per realm with /gb ah).
function GB.AH()
  return GB.db.realmAH[GetRealmName() or "?"] or GB.DEFAULT_AH
end

-- Unique, increasing ids for ledger entries (the dashboard merges by id, so nothing counts twice).
function GB.NextID()
  GB.db.seq = (GB.db.seq or 0) + 1
  return string.format("%d-%d", time(), GB.db.seq)
end

---------------------------------------------------------------------------
-- Saved data
---------------------------------------------------------------------------

local function InitDB()
  GoldBoardDB = GoldBoardDB or {}
  local db = GoldBoardDB
  db.version = GB.version
  db.chars = db.chars or {}       -- [character] = { class, realm, faction, gold = { {t, copper}, ... } }
  db.ledger = db.ledger or {}     -- every buy, sale, post, cancel and expiry, oldest first
  db.scans = db.scans or {}       -- copies of Auctionator's full scans (the newest MAX_SCANS)
  db.names = db.names or {}       -- item name -> item id
  db.holdings = db.holdings or {} -- [itemID] = count across characters (Syndicator), refreshed at the AH and on logout
  db.realmAH = db.realmAH or {}   -- [realm name] = TSM auction house id
  db.settings = db.settings or {}
  GB.db = db
end

---------------------------------------------------------------------------
-- Gold over time
---------------------------------------------------------------------------

function GB.SampleGold()
  local copper = GB.Clean(GetMoney())
  if not copper then return end
  local key = GB.Character()
  local c = GB.db.chars[key]
  if not c then
    c = { gold = {} }
    GB.db.chars[key] = c
  end
  c.class = select(2, UnitClass("player"))
  c.realm = GetRealmName()
  c.faction = UnitFactionGroup("player")
  c.ah = GB.AH()
  local now, n = time(), #c.gold
  if n > 0 and c.gold[n][2] == copper then return end
  -- the previous kept sample is under 5 minutes old: the newest value replaces the last one
  if n >= 2 and now - c.gold[n - 1][1] < GOLD_SAMPLE_SEC then
    c.gold[n] = { now, copper }
  else
    c.gold[n + 1] = { now, copper }
  end
end

---------------------------------------------------------------------------
-- Events and slash commands
---------------------------------------------------------------------------

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("PLAYER_MONEY")
ev:RegisterEvent("PLAYER_LOGOUT")
ev:SetScript("OnEvent", function(_, event, arg1)
  if event == "ADDON_LOADED" and arg1 == ADDON then
    InitDB()
  elseif event == "PLAYER_LOGIN" then
    GB.SampleGold()
    if GB.Signals then GB.Signals.Load() end
    if GB.Ledger then GB.Ledger.Init() end
    if GB.Scans then GB.Scans.Init() end
  elseif event == "PLAYER_MONEY" then
    GB.SampleGold()
  elseif event == "PLAYER_LOGOUT" then
    GB.SampleGold()
    if GB.Ledger then GB.Ledger.RefreshHoldings() end
  end
end)

local HELP = {
  "/gb - open the Gold Board window: overview, deals, what you hold (and when to sell it), ledger",
  "/gb auction - show or hide the Gold Board window beside the auction house (Shop, Sell, Cancel)",
  "/gb ah <id> - the TSM auction house this realm uses (now %s), e.g. roleplay-alliance, normal-alliance",
  "/gb status - what has been recorded so far",
}

SLASH_GOLDBOARD1 = "/gb"
SLASH_GOLDBOARD2 = "/goldboard"
SlashCmdList.GOLDBOARD = function(msg)
  local cmd, arg = (msg or ""):lower():match("^%s*(%S*)%s*(.-)%s*$")
  if cmd == "" then
    GB.Main.Toggle()
  elseif cmd == "auction" or cmd == "ah" and arg == "" then
    GB.AHWindow.Toggle()
  elseif cmd == "ah" and arg ~= "" then
    GB.db.realmAH[GetRealmName() or "?"] = arg
    GB.Print("prices for " .. (GetRealmName() or "this realm") .. " now come from " .. arg .. ". /reload to load them.")
  elseif cmd == "status" then
    local buys, sells = 0, 0
    for _, e in ipairs(GB.db.ledger) do
      if e.kind == "buy" then buys = buys + 1 elseif e.kind == "sell" then sells = sells + 1 end
    end
    GB.Print(string.format("%d buys, %d sales, %d saved scans. Prices: %s, %s.", buys, sells, #GB.db.scans, GB.AH(),
      GB.Signals and GB.Signals.Describe() or "no signals"))
  else
    for _, line in ipairs(HELP) do print(line:find("%%s") and line:format(GB.AH()) or line) end
  end
end
