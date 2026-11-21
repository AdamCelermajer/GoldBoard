-- What the dashboard gets from the game besides the ledger (it reads GoldBoardDB after a /reload or logout):
--   auctionator : Auctionator's own daily price history (lowest and highest seen, how many were up, per day)
--                 for the items the dashboard tracks or you trade, so its charts reach back before Gold Board
-- And the other way: the dashboard writes SignalsData.lua, read at login (Signals.lua).

local _, GB = ...
local S = {}
GB.Sync = S

local MAX_ITEMS = 4000

function S.ExportAuctionator()
  local db = Auctionator and Auctionator.Database and Auctionator.Database.db
  if type(db) ~= "table" then return end
  local day0 = Auctionator.Constants and Auctionator.Constants.SCAN_DAY_0
  if not day0 then return end
  -- which items: everything with a Gold Board signal, plus what you traded
  local want = {}
  for id in pairs(GB.Signals.All()) do want[id] = true end
  for _, e in ipairs(GB.db.ledger) do if e.itemID then want[e.itemID] = true end end
  local items, n = {}, 0
  for id in pairs(want) do
    local d = db[tostring(id)]
    if type(d) == "table" and type(d.h) == "table" then
      local parts = {}
      for day, high in pairs(d.h) do
        local low = d.l and d.l[day] or high
        local avail = d.a and d.a[day] or ""
        parts[#parts + 1] = string.format("%s:%s:%s:%s", tostring(day), tostring(low), tostring(high), tostring(avail))
      end
      if #parts > 0 then
        items[id] = table.concat(parts, ",")
        n = n + 1
        if n >= MAX_ITEMS then break end
      end
    end
  end
  GB.db.auctionator = { t = time(), day0 = day0, ah = GB.AH(), realm = GB.Realm(), items = items }
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGOUT")
f:SetScript("OnEvent", function() pcall(S.ExportAuctionator) end)
