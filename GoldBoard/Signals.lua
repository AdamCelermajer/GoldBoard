-- Reads the dashboard's signals (SignalsData.lua) for this realm's auction house.
-- One entry per item: "sell:buyBelow:market:minBuy:trend:soldPerDay:buyHour:sellHour:spread"
--   sell      what it realistically sells for (copper)
--   buyBelow  the price under which a buy leaves room for profit
--   market    TSM market value; minBuy the cheapest listing at the last TSM update
--   trend     % change of the cheapest listing over the last day; soldPerDay EU-wide sales a day

local _, GB = ...
local S = {}
GB.Signals = S

local items = {}   -- [itemID] = parsed entry, for GB.AH()
local meta = {}

function S.Load()
  items, meta = {}, {}
  local data = _G.GoldBoardSignalsData
  if type(data) ~= "table" or type(data.ah) ~= "table" then return end
  local ah = GB.AH()
  local list = data.ah[ah]
  if type(list) ~= "table" then return end
  meta = { generated = data.generated, tsm = data.tsm and data.tsm[ah], ah = ah, label = data.labels and data.labels[ah] or ah }
  for id, s in pairs(list) do
    local sell, below, market, minBuy, trend, sold, buyHour, sellHour, spread = strsplit(":", s)
    items[tonumber(id)] = {
      sell = tonumber(sell), buyBelow = tonumber(below), market = tonumber(market),
      minBuy = tonumber(minBuy), trend = tonumber(trend), soldPerDay = tonumber(sold),
      buyHour = tonumber(buyHour), sellHour = tonumber(sellHour), spread = tonumber(spread),
    }
  end
  meta.count = 0
  for _ in pairs(items) do meta.count = meta.count + 1 end
end

function S.Get(itemID) return itemID and items[itemID] end
function S.Meta() return meta end
function S.All() return items end

function S.Describe()
  if not meta.count or meta.count == 0 then return "no signals yet (start the Gold Board on your PC, then /reload)" end
  local age = meta.tsm and math.floor((time() - meta.tsm) / 3600) or nil
  return string.format("%d items from %s%s", meta.count, meta.label, age and string.format(", TSM data %dh old", age) or "")
end
