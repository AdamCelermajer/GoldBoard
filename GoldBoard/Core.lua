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

GB.version = "2.3.4"
GB.DEFAULT_AH = "roleplay-alliance"   -- the TSM auction house id (ruleset-faction) prices come from

local GOLD_SAMPLE_SEC = 300   -- at most one gold sample per character every 5 minutes (the newest replaces it)

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

function GB.Print(msg) print("|cffe0b44cGold Board|r: " .. msg) end

-- Values can be "secret" in Forever while restrictions are active: treat them as unknown.
function GB.Clean(v)
  if v ~= nil and issecretvalue and issecretvalue(v) then return nil end
  return v
end

-- An error of ours: the whole text with its file and line goes to chat (once per error, so you can send
-- it on), then to the game's own error handler. This client's messages name no function, so the line is
-- what finds it.
local reported = {}
function GB.Report(err, where)
  err = tostring(err)
  if not reported[err] then
    reported[err] = true
    print("|cffe0655aGold Board error|r" .. (where and (" (" .. where .. ")") or "") .. ": " .. err)
  end
  local handler = geterrorhandler and geterrorhandler()
  if handler then handler(err) end
end

-- The game refuses some calls from addons (it then says "Interface action failed because of an AddOn" and
-- nothing else). It also tells addons which function it refused: that is printed, and handed to whoever
-- is waiting on a post, a buy or a cancel, so the failure names the function instead of "no answer".
-- Everything is also kept in the saved data (GoldBoardDB.diag, the newest 20 of each), so a failure can
-- be read from the SavedVariables file after a /reload:
--   diag.calls   each post, buy and cancel call: what was sent, what the game returned (nil, false and
--                true are different answers), whether its throttle was ready, any block that followed
--   diag.blocks  every call the game blocked while the auction house was open, whoever it blamed
GB.inFlight = nil            -- the diag.calls entry of the post, buy or cancel just sent
local WATCH = 10             -- seconds after a call in which a block is taken to be about it
local blockedListeners = {}
function GB.OnBlocked(fn) blockedListeners[#blockedListeners + 1] = fn end

local function Keep(list, entry)
  list[#list + 1] = entry
  while #list > 20 do table.remove(list, 1) end
  return entry
end
local function Diag()
  if not GB.db then return { calls = {}, blocks = {} } end
  GB.db.diag = GB.db.diag or {}
  GB.db.diag.calls, GB.db.diag.blocks = GB.db.diag.calls or {}, GB.db.diag.blocks or {}
  return GB.db.diag
end

-- written just before the call (so even a call that never comes back is on record)
function GB.CallStarted(what, call)
  local ready = C_AuctionHouse and C_AuctionHouse.IsThrottledMessageSystemReady
  GB.inFlight = Keep(Diag().calls, { t = time(), at = GetTime(), what = what, call = call or what, returned = "(the call did not come back: a Lua error, see Blizzard_Console.lua)",
    throttle = ready == nil and "unknown" or (ready() and "ready" or "busy"), version = GB.version })
  return GB.inFlight
end
function GB.CallReturned(entry, result)
  entry.returned = result == nil and "nil" or tostring(result)
  entry.back = true      -- a watcher armed before the call that never sees this knows the call raised an error
end
-- the facts of the last call in one line, for a row that would otherwise say "no answer"
function GB.CallFacts(entry)
  entry = entry or GB.inFlight
  if not entry then return "no call was made" end
  return (entry.blocked and ("the game blocked " .. entry.blocked) or "the game reported no blocked call")
    .. "; " .. tostring(entry.call):match("^[%w_%.]+") .. " returned " .. tostring(entry.returned) .. "; throttle " .. tostring(entry.throttle)
end

local blockWatch = CreateFrame("Frame")
pcall(blockWatch.RegisterEvent, blockWatch, "ADDON_ACTION_BLOCKED")
pcall(blockWatch.RegisterEvent, blockWatch, "ADDON_ACTION_FORBIDDEN")
blockWatch:SetScript("OnEvent", function(_, event, addon, func)
  local ours = type(addon) == "string" and addon:lower() == "goldboard"
  local flying = GB.inFlight and GetTime() - GB.inFlight.at < WATCH and GB.inFlight or nil
  local atAH = GB.Query and GB.Query.Open and GB.Query.Open()
  if not (ours or flying or atAH) then return end
  func = tostring(func or "something")
  local text = func .. " (blamed on " .. tostring(addon) .. (event == "ADDON_ACTION_FORBIDDEN" and ", forbidden to addons" or "") .. ")"
  Keep(Diag().blocks, { t = time(), event = event, addon = tostring(addon), func = func, during = flying and flying.call or nil })
  if not (ours or flying) then return end       -- somebody else's, with nothing of ours pending: kept, not shown
  if flying then flying.blocked = flying.blocked and (flying.blocked .. ", " .. text) or text end
  GB.blockedNow = text       -- seen by the click that made the call, when the game refuses it on the spot
  print("|cffe0655aGold Board|r: the game blocked " .. text .. (flying and (", during " .. flying.what) or "") .. ".")
  for _, fn in ipairs(blockedListeners) do pcall(fn, text, tostring(addon), event) end
end)

-- fn wrapped so an error in it is reported instead of vanishing (click handlers run with errors hidden)
function GB.Safe(fn, where)
  return function(...)
    local ok, err = pcall(fn, ...)
    if not ok then GB.Report(err, where) end
  end
end

function GB.Money(c)
  c = GB.Clean(c)
  if not c then return "?" end
  local neg = c < 0
  c = math.floor(math.abs(c) + 0.5)
  local g, s, cc = math.floor(c / 10000), math.floor(c / 100) % 100, c % 100
  local out
  if g > 0 then out = string.format("|cffe0b44c%dg|r |cffc4c0b6%ds|r", g, s)
  elseif s > 0 then out = string.format("|cffc4c0b6%ds|r |cffc9814e%dc|r", s, cc)
  else out = string.format("|cffc9814e%dc|r", cc) end
  return (neg and "-" or "") .. out
end

-- how many of an item are in your bags right now (every stack, the reagent bag included)
function GB.BagCount(itemID)
  local slots = C_Container and C_Container.GetContainerNumSlots
  local item = C_Container and C_Container.GetContainerItemInfo
  if not (slots and item and itemID) then return nil end
  local n = 0
  for bag = 0, (NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4) do
    for slot = 1, slots(bag) or 0 do
      local info = item(bag, slot)
      if info and info.itemID == itemID then n = n + (info.stackCount or 1) end
    end
  end
  return n
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

-- The realm's name. This client sometimes answers "" for it, which once split one character into two
-- ("Name-Realm" and "Name-"), counting its gold twice. An empty answer is taken as "not known": the realm
-- remembered from an earlier answer comes first (the game's normalized name is spelled differently, so it
-- would split the character again), then the normalized name, then "?".
function GB.Realm()
  local r = GetRealmName and GetRealmName()
  if type(r) == "string" and r ~= "" then
    if GB.db then GB.db.realm = r end
    return r
  end
  if GB.db and type(GB.db.realm) == "string" and GB.db.realm ~= "" then return GB.db.realm end
  r = GetNormalizedRealmName and GetNormalizedRealmName()
  if type(r) == "string" and r ~= "" then return r end
  return "?"
end

-- "First Last" for Forever characters (UnitName returns both parts), with the realm.
function GB.Character()
  local first, last = UnitName("player")
  local name = (last and last ~= "") and (first .. " " .. last) or first
  return name .. "-" .. GB.Realm()
end

-- Which TSM auction house this character's prices come from (set per realm with /gb ah).
function GB.AH()
  return GB.db.realmAH[GB.Realm()] or GB.DEFAULT_AH
end

-- Unique, increasing ids for ledger entries (the dashboard merges by id, so nothing counts twice).
function GB.NextID()
  GB.db.seq = (GB.db.seq or 0) + 1
  return string.format("%d-%d", time(), GB.db.seq)
end

---------------------------------------------------------------------------
-- Saved data
---------------------------------------------------------------------------

-- A character saved while the game answered an empty realm ("Name-", or "Name-?" from an older version)
-- is the same character as "Name-Realm": its gold samples are merged into that one, so its gold counts
-- once. Only done when exactly one realm is known (else which realm it was can't be told), and every load,
-- so a split made by an older version on another character is mended too.
local function Realmless(key)
  if type(key) ~= "string" then return nil end
  return key:match("^(.-)%-%??$")
end
local function MergeRealmless(db)
  local known, realm, n = {}, nil, 0
  if type(db.realm) == "string" and db.realm ~= "" and db.realm ~= "?" then known[db.realm] = true end
  for _, c in pairs(db.chars) do
    if type(c) == "table" and type(c.realm) == "string" and c.realm ~= "" and c.realm ~= "?" then known[c.realm] = true end
  end
  for r in pairs(known) do realm, n = r, n + 1 end
  if n ~= 1 then return end
  db.realm = realm
  local keys = {}
  for key in pairs(db.chars) do if Realmless(key) then keys[#keys + 1] = key end end
  for _, key in ipairs(keys) do
    local from, target = db.chars[key], Realmless(key) .. "-" .. realm
    local into = db.chars[target]
    if type(into) ~= "table" then
      db.chars[target] = from
    elseif type(from) == "table" then
      local all, seen, order = {}, {}, {}
      for _, list in ipairs({ into.gold or {}, from.gold or {} }) do
        for _, s in ipairs(list) do
          local k = type(s) == "table" and s[1] and (tostring(s[1]) .. ":" .. tostring(s[2]))
          if k and not seen[k] then seen[k] = true; all[#all + 1] = s; order[s] = #all end
        end
      end
      table.sort(all, function(a, b) if a[1] ~= b[1] then return a[1] < b[1] end return order[a] < order[b] end)
      into.gold = all
      for k, v in pairs(from) do if into[k] == nil then into[k] = v end end
    end
    if type(db.chars[target]) == "table" then db.chars[target].realm = realm end
    db.chars[key] = nil
  end
  for _, e in ipairs(db.ledger) do
    if type(e) == "table" and Realmless(e.char) then e.char = Realmless(e.char) .. "-" .. realm end
  end
  for _, bad in ipairs({ "", "?" }) do
    if db.realmAH[bad] ~= nil then
      if db.realmAH[realm] == nil then db.realmAH[realm] = db.realmAH[bad] end
      db.realmAH[bad] = nil
    end
  end
  for _, s in ipairs(db.scans) do if type(s) == "table" and (s.realm == "" or s.realm == "?") then s.realm = realm end end
  if type(db.auctionator) == "table" and (db.auctionator.realm == "" or db.auctionator.realm == "?") then db.auctionator.realm = realm end
end
GB.MergeRealmless = MergeRealmless

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
  db.groups = nil                 -- groups were removed in 2.1
  -- before 2.2 a sample was taken while logging out, when the game already answers 0 gold: drop those
  if not db.settings.zeroGoldFixed then
    for _, c in pairs(db.chars) do
      if type(c.gold) == "table" then
        local kept = {}
        for _, s in ipairs(c.gold) do
          if not (s[2] == 0 and #kept > 0) then kept[#kept + 1] = s end
        end
        c.gold = kept
      end
    end
    db.settings.zeroGoldFixed = true
    db.settings.mainTab = nil     -- 2.2 opens on Deals
  end
  MergeRealmless(db)
  GB.db = db
end
GB.InitDB = InitDB

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
  c.realm = GB.Realm()
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
    -- a file that stopped half way while loading leaves its functions missing: say which, instead of
    -- every button failing later with "attempt to call a nil value"
    for _, m in ipairs({ { "UI\\Theme.lua", GB.UI, "Table" }, { "Ledger.lua", GB.Ledger, "Init" }, { "Signals.lua", GB.Signals, "Load" },
                         { "Pricing.lua", GB.Pricing, "Deals" }, { "AH\\Query.lua", GB.Query, "Forget" },
                         { "AH\\Window.lua", GB.AHWindow, "Toggle" }, { "UI\\Main.lua", GB.Main, "Toggle" } }) do
      if not (m[2] and m[2][m[3]]) then
        GB.Print("|cffe0655a" .. m[1] .. " did not load completely|r: type /console scriptErrors 1, /reload, and send the error shown.")
      end
    end
  elseif event == "PLAYER_MONEY" then
    GB.SampleGold()
  elseif event == "PLAYER_LOGOUT" then
    -- no gold sample here: while logging out the game answers 0 (every change was sampled as it happened)
    if GB.Ledger then GB.Ledger.RefreshHoldings() end
  end
end)

local HELP = {
  "/gb - open the Gold Board window: deals, when to sell what you hold, overview, ledger",
  "/gb auction - show or hide the Gold Board window beside the auction house (Shop, Sell, Cancel)",
  "/gb ah <id> - the TSM auction house this realm uses (now %s), e.g. roleplay-alliance, normal-alliance",
  "/gb status - what has been recorded so far",
  "/gb diag - the last posts, buys and cancels sent to the game, what it answered, and anything it blocked",
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
    GB.db.realmAH[GB.Realm()] = arg
    if GB.Signals then GB.Signals.Load() end
    GB.Print("prices for " .. GB.Realm() .. " now come from " .. arg .. ": "
      .. (GB.Signals and GB.Signals.Describe() or "no signals") .. ".")
    if GB.Main and GB.Main.Refresh then GB.Main.Refresh() end
  elseif cmd == "diag" then
    local diag = GB.db.diag or {}
    local calls, blocks = diag.calls or {}, diag.blocks or {}
    GB.Print("version " .. GB.version .. ". Last calls (newest last):")
    if #calls == 0 then print("  none yet") end
    for i = math.max(1, #calls - 4), #calls do
      local c = calls[i]
      print(string.format("  %s  %s -> returned %s; throttle %s%s", date("%H:%M:%S", c.t), tostring(c.call), tostring(c.returned), tostring(c.throttle),
        c.blocked and ("; BLOCKED: " .. c.blocked) or ""))
    end
    print("Blocked by the game while the auction house was open:")
    if #blocks == 0 then print("  none recorded") end
    for i = math.max(1, #blocks - 4), #blocks do
      local b = blocks[i]
      print(string.format("  %s  %s, blamed on %s%s", date("%H:%M:%S", b.t), tostring(b.func), tostring(b.addon), b.during and (", during " .. b.during) or ""))
    end
  elseif cmd == "status" then
    local buys, sells = 0, 0
    for _, e in ipairs(GB.db.ledger) do
      if e.kind == "buy" then buys = buys + 1 elseif e.kind == "sell" then sells = sells + 1 end
    end
    GB.Print(string.format("version %s. %d buys, %d sales, %d saved scans. Prices: %s, %s.", GB.version, buys, sells, #GB.db.scans, GB.AH(),
      GB.Signals and GB.Signals.Describe() or "no signals"))
  else
    for _, line in ipairs(HELP) do print(line:find("%%s") and line:format(GB.AH()) or line) end
  end
end
