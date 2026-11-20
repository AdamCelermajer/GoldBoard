-- How Gold Board prices what you sell and when it says to buy or sell. One set of rules for everything:
--   floor    never post below this share of the item's usual price (an item being dumped waits instead)
--   normal   the price when nobody else sells it
--   ceiling  never post above this (one silly listing doesn't drag you up)
--   undercut how far under the cheapest other seller to go, per item
-- "Usual price" is the Gold Board's "sells for", or Auctionator's last scan when the dashboard has none.

local _, GB = ...
local P = {}
GB.Pricing = P

P.DEFAULTS = { floor = 80, normal = 120, ceiling = 200, undercut = 1, stacks = 5, duration = 1 }

function P.Rules()
  GB.db.settings.pricing = GB.db.settings.pricing or {}
  local r = GB.db.settings.pricing
  for k, v in pairs(P.DEFAULTS) do if r[k] == nil then r[k] = v end end
  return r
end

function P.Value(itemID)
  local s = GB.Signals.Get(itemID)
  if s and s.sell and s.sell > 0 then return s.sell, "Gold Board" end
  local api = Auctionator and Auctionator.API and Auctionator.API.v1 and Auctionator.API.v1.GetAuctionPriceByItemID
  if api then
    local ok, p = pcall(api, "Gold Board", itemID)
    if ok and p and p > 0 then return p, "Auctionator" end
  end
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
  if mineLowest then return nil, "yours is already the cheapest" end
  if not lowest then return prices.normal, "nobody else sells it" end
  local under = lowest - r.undercut
  if under > prices.ceiling then return prices.ceiling, "others ask far more: at your ceiling" end
  if under < prices.floor then return nil, "being dumped under its usual price: hold" end
  return under, "undercutting the cheapest"
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
  if HoursApart(now, s.sellHour) <= 1 then return "now is its dearest time", true end
  if s.buyHour and HoursApart(now, s.buyHour) <= 1 then
    return string.format("now is its cheapest time: wait for ~%d:00 (+%d%%)", s.sellHour, s.spread or 0), false
  end
  return string.format("dearest around %d:00 (+%d%% over its cheap hour)", s.sellHour, s.spread or 0), nil
end

function P.BuyTiming(s)
  if not s or not s.buyHour then return nil end
  local now = tonumber(date("%H"))
  if HoursApart(now, s.buyHour) <= 1 then return "now is its cheapest time", true end
  return string.format("cheapest around %d:00", s.buyHour), nil
end
