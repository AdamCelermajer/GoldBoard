-- Copies of Auctionator's full scans: every item on your auction house, with quantities, at the
-- hours you're there. TSM's public data only updates every 3 hours and has no quantities; these
-- fill both gaps on the Gold Board. Nothing is scanned here: Auctionator's own scan (at most one
-- every 15 minutes, started when you open the auction house) is read when it finishes.
--
-- One scan is saved as a compact string, "itemID:min:p25:qty:auctions:sellers;..." (unit prices
-- in copper; p25 = the price a quarter of the way into the listed quantity, cheapest first),
-- so 30 scans stay a few MB. Seller names are not kept, only how many sellers there were.

local _, GB = ...
local S = {}
GB.Scans = S

local MAX_SCANS = 30

local function Summarize(raw)
  local items = {}
  for _, entry in ipairs(raw) do
    local info = entry.auctionInfo
    local count, buyout, owner, itemID = info and info[3], info and info[10], info and info[14], info and info[17]
    if itemID and itemID > 0 and count and count > 0 and buyout and buyout > 0 then
      local it = items[itemID]
      if not it then
        it = { listings = {}, sellers = {}, nSellers = 0, qty = 0, auctions = 0 }
        items[itemID] = it
      end
      it.listings[#it.listings + 1] = { unit = buyout / count, qty = count }
      it.qty = it.qty + count
      it.auctions = it.auctions + 1
      if owner and not it.sellers[owner] then it.sellers[owner] = true; it.nSellers = it.nSellers + 1 end
      local name = info[1]
      if name then GB.LearnName(name, itemID) end
    end
  end
  local parts = {}
  for itemID, it in pairs(items) do
    table.sort(it.listings, function(a, b) return a.unit < b.unit end)
    local quarter, seen, p25 = it.qty * 0.25, 0, it.listings[1].unit
    for _, l in ipairs(it.listings) do
      seen = seen + l.qty
      if seen >= quarter then p25 = l.unit; break end
    end
    parts[#parts + 1] = string.format("%d:%d:%d:%d:%d:%d", itemID, math.ceil(it.listings[1].unit), math.ceil(p25),
      it.qty, it.auctions, it.nSellers)
  end
  return table.concat(parts, ";"), #parts
end

local function OnScanComplete(raw)
  if type(raw) ~= "table" or #raw == 0 then return end
  local data, n = Summarize(raw)
  local scans = GB.db.scans
  scans[#scans + 1] = { t = time(), ah = GB.AH(), realm = GetRealmName(), auctions = #raw, items = n, data = data }
  while #scans > MAX_SCANS do table.remove(scans, 1) end
  GB.Print(string.format("saved this auction house scan (%d items) for the Gold Board.", n))
end

function S.Init()
  local bus = Auctionator and Auctionator.EventBus
  local events = Auctionator and Auctionator.FullScan and Auctionator.FullScan.Events
  if not (bus and events and events.ScanComplete) then return end
  pcall(bus.Register, bus, { ReceiveEvent = function(_, eventName, raw)
    if eventName == events.ScanComplete then OnScanComplete(raw) end
  end }, { events.ScanComplete })
end
