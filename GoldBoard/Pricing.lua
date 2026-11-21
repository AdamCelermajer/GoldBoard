-- How Gold Board prices what you sell and when it says to buy or sell. One set of rules for everything:
--   floor    never post below this share of the item's usual price (an item being dumped waits instead)
--   normal   the price when nobody else sells it
--   ceiling  never post above this (one silly listing doesn't drag you up)
--   undercut how far under the cheapest other seller to go, per item
-- "Usual price" is the Gold Board's "sells for", or Auctionator's last scan when the dashboard has none.

local _, GB = ...
local P = {}
GB.Pricing = P

-- duration: 1, 2 or 3 = the auction house's short, medium or long (2, 8 and 24 hours on this client)
P.DEFAULTS = { floor = 80, normal = 120, ceiling = 200, undercut = 1, duration = 1 }

function P.Rules()
  GB.db.settings.pricing = GB.db.settings.pricing or {}
  local r = GB.db.settings.pricing
  for k, v in pairs(P.DEFAULTS) do if r[k] == nil then r[k] = v end end
  return r
end

function P.Value(itemID)
  local s = GB.Signals.Get(itemID)
  if s and s.sell and s.sell > 0 then return s.sell, "Gold Board" end
  local p = P.AuctionatorPrice(itemID)
  if p then return p, "Auctionator" end
end

-- { floor, normal, ceiling, value } in copper per item, or nil when the item has no known price
function P.Prices(itemID)
  local value, source = P.Value(itemID)
  if not value then return nil end
  local r = P.Rules()
  return { floor = math.floor(value * r.floor / 100), normal = math.floor(value * r.normal / 100),
           ceiling = math.floor(value * r.ceiling / 100), value = value, source = source }
end

-- A post price from the live listings: lowest = cheapest other seller (nil = nobody), mineLowest = yours is.
-- Returns the unit price and why, or nil and why not.
function P.PostPrice(prices, lowest, mineLowest)
  local r = P.Rules()
  if not prices then return nil, "no price known yet" end
  if mineLowest then return nil, "yours is the cheapest" end
  if not lowest then return prices.normal, "nobody else sells it" end
  local under = lowest - r.undercut
  if under > prices.ceiling then return prices.ceiling, "others ask far more" end
  if under < prices.floor then return nil, "dumped under its usual price: hold" end
  return under, "undercuts the cheapest"
end

-- distance between two hours on the clock
local function HoursApart(a, b)
  local d = math.abs(a - b)
  return math.min(d, 24 - d)
end

-- Timing advice for selling from the dashboard's hour-of-day data (TSM updates every 3 hours, so
-- "around" means within the hour or so either side). Returns text and whether now is a good time.
function P.SellTiming(s)
  if not s or not s.sellHour then return nil end
  local now = tonumber(date("%H"))
  if HoursApart(now, s.sellHour) <= 1 then return "dearest about now", true end
  if s.buyHour and HoursApart(now, s.buyHour) <= 1 then
    return string.format("wait for ~%d:00 (+%d%%): cheapest now", s.sellHour, s.spread or 0), false
  end
  return string.format("best ~%d:00 (+%d%%)", s.sellHour, s.spread or 0), nil
end

function P.BuyTiming(s)
  if not s or not s.buyHour then return nil end
  local now = tonumber(date("%H"))
  if HoursApart(now, s.buyHour) <= 1 then return "cheapest about now", true end
  return string.format("cheapest ~%d:00", s.buyHour), nil
end

---------------------------------------------------------------------------
-- The cheapest listing known right now, and the deals that follow from it
---------------------------------------------------------------------------

-- Auctionator's last seen cheapest price for an item and how many days ago it saw it (0 = today)
function P.AuctionatorPrice(itemID)
  local api = Auctionator and Auctionator.API and Auctionator.API.v1
  if not (api and api.GetAuctionPriceByItemID) or type(itemID) ~= "number" then return nil end
  local ok, p = pcall(api.GetAuctionPriceByItemID, "Gold Board", itemID)
  if not ok or type(p) ~= "number" or p <= 0 then return nil end
  local age
  if api.GetAuctionAgeByItemID then
    local okAge, a = pcall(api.GetAuctionAgeByItemID, "Gold Board", itemID)
    if okAge and type(a) == "number" then age = a end
  end
  return p, age
end

-- when Auctionator's last full scan ran (nil when unknown)
local function LastFullScan()
  local st = Auctionator and Auctionator.SavedState
  local t = st and st.TimeOfLastGetAllScan
  return type(t) == "number" and t or nil
end

-- The cheapest listing of an item, from whichever source saw the auction house last: Auctionator's scan
-- or the Gold Board's TSM update. Returns the price and "scan" or "TSM"; nil when nobody had it listed.
function P.Cheapest(itemID, s)
  s = s or GB.Signals.Get(itemID)
  local ac, age = P.AuctionatorPrice(itemID)
  local tsm = s and s.minBuy and s.minBuy > 0 and s.minBuy or nil
  local tsmTime = s and GB.Signals.Meta().tsm or nil
  if not s or not tsmTime then return ac, ac and "scan" or nil end   -- no dashboard data for this item
  if ac then
    if age == nil then return ac, "scan" end
    if age == 0 then
      local scan = LastFullScan()
      -- seen today: Auctionator wins unless the TSM update is known to be newer than its scan
      if not scan or scan >= tsmTime or time() - scan < 3600 then return ac, "scan" end
    end
  end
  -- the TSM update is the newer look at the auction house (0 there means nothing was listed)
  if time() - tsmTime < 86400 or not ac then return tsm, tsm and "TSM" or nil end
  -- both are old: the more recent one
  if age and age * 86400 < time() - tsmTime then return ac, "scan" end
  return tsm or ac, tsm and "TSM" or "scan"
end

-- What's worth buying: listed under its buy-below price and actually selling. Best first.
function P.Deals()
  local list = {}
  for id, s in pairs(GB.Signals.All()) do
    if s.sell and s.buyBelow and (s.soldPerDay or 0) >= 1 then
      local cheapest, source = P.Cheapest(id, s)
      if cheapest and cheapest > 0 and cheapest <= s.buyBelow then
        local profit = s.sell * 0.95 - cheapest
        local when, good = P.BuyTiming(s)
        list[#list + 1] = { itemID = id, name = C_Item.GetItemNameByID(id) or ("item " .. id), cheapest = cheapest,
          buyBelow = s.buyBelow, sell = s.sell, profit = profit, margin = profit / cheapest, trend = s.trend,
          sold = s.soldPerDay, score = profit * math.min(s.soldPerDay, 50), when = when, whenGood = good, source = source }
      end
    end
  end
  table.sort(list, function(a, b) return a.score > b.score end)
  return list
end

-- names the game hadn't loaded when a list was built arrive a moment later: fill them in, then refresh()
function P.FillNames(list, refresh)
  local missing = false
  for _, d in ipairs(list) do
    if d.name:find("^item ") then
      missing = true
      if C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(d.itemID) end
    end
  end
  if not missing then return end
  C_Timer.After(1.5, function()
    local changed = false
    for _, d in ipairs(list) do
      if d.name:find("^item ") then
        local n = C_Item.GetItemNameByID(d.itemID)
        if n then d.name, changed = n, true end
      end
    end
    if changed then refresh() end
  end)
end
