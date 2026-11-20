-- Auction house searches, one item at a time (exact name, every page up to MAX_PAGES), in a queue.
-- Shares the auction house politely with Auctionator: waits for the server's query cooldown, pauses
-- while Auctionator's full scan runs, and ignores results of searches someone else sent.
--
-- Q.Search(itemID, name, cb)  cb(result) with result = {
--   itemID, name, auctions = { { page, index, unit, count, buyout, bid, owner, mine } }, lowest (others),
--   lowestMine, mineCount, time }
-- Q.LoadPage(name, page, cb)  loads one page into the auction house list so a row on it can be bought.

local _, GB = ...
local Q = {}
GB.Query = Q

local MAX_PAGES = 6        -- 300 listings: plenty for one item
local SETTLE = 0.3         -- owner names arrive a moment after the first result event
local TIMEOUT = 10

local queue, job = {}, nil
local sending, lastByUs = false, false
local auctionatorScanning = false
Q.cache = {}               -- [itemID] = last result (posting and cancelling reuse it for a few minutes)
Q.listPage = nil           -- "name|page" currently in the auction house list, when we loaded it

local function MyNames()
  local names = {}
  local full = GetUnitName and GetUnitName("player")
  local first, last = UnitName("player")
  for _, n in ipairs({ full, first, last and (first .. " " .. last) or nil }) do if n then names[n] = true end end
  return names
end

function Q.IsMine(owner)
  if not owner then return false end
  Q.myNames = Q.myNames or MyNames()
  return Q.myNames[owner] or Q.myNames[(owner:gsub("%-.*$", ""))] or false
end

hooksecurefunc("QueryAuctionItems", function() lastByUs = sending; if not sending then Q.listPage = nil end end)

local function Send()
  if not job or job.waiting then return end
  if not (AuctionFrame and AuctionFrame:IsShown()) or auctionatorScanning then return end
  local canQuery = CanSendAuctionQuery()
  if not canQuery then return end
  job.waiting, job.sentAt, job.readAt = true, GetTime(), nil
  sending = true
  QueryAuctionItems(job.name, nil, nil, job.page, false, nil, false, true)
  sending = false
end

local function ReadPage()
  local n, total = GetNumAuctionItems("list")
  for i = 1, n do
    local name, _, count, _, _, _, _, minBid, _, buyout, bidAmount, _, _, owner, ownerFull, saleStatus, itemID = GetAuctionItemInfo("list", i)
    if itemID == job.itemID or (not job.itemID and name == job.name) then
      if count and count > 0 and buyout and buyout > 0 then
        local mine = Q.IsMine(owner) or Q.IsMine(ownerFull)
        job.auctions[#job.auctions + 1] = { page = job.page, index = i, unit = buyout / count, count = count, buyout = buyout,
          bid = bidAmount or 0, minBid = minBid, owner = owner, mine = mine }
      end
    end
  end
  return n, total or 0
end

local function Finish()
  local r = { itemID = job.itemID, name = job.name, auctions = job.auctions, time = time(), mineCount = 0 }
  table.sort(r.auctions, function(a, b) return a.unit < b.unit end)
  for _, a in ipairs(r.auctions) do
    if a.mine then
      r.mineCount = r.mineCount + a.count
      r.lowestMine = r.lowestMine or a.unit
    else
      r.lowest = r.lowest or a.unit
    end
  end
  if job.itemID then Q.cache[job.itemID] = r end
  local cb = job.cb
  job = nil
  if cb then pcall(cb, r) end
end

local f = CreateFrame("Frame")
f:RegisterEvent("AUCTION_ITEM_LIST_UPDATE")
f:RegisterEvent("AUCTION_HOUSE_CLOSED")
f:SetScript("OnEvent", function(_, event)
  if event == "AUCTION_HOUSE_CLOSED" then
    queue, job, Q.listPage = {}, nil, nil
  elseif job and job.waiting then
    if lastByUs then job.readAt = GetTime() + SETTLE else job.waiting = false end   -- someone else's search: send ours again
  end
end)
f:SetScript("OnUpdate", function()
  if not job and #queue > 0 then job = table.remove(queue, 1) end
  if not job then return end
  if job.waiting then
    if job.readAt and GetTime() >= job.readAt then
      local n, total = ReadPage()
      Q.listPage = job.name .. "|" .. job.page
      if job.single or (job.page + 1) * 50 >= total or job.page + 1 >= MAX_PAGES or n == 0 then
        Finish()
      else
        job.page, job.waiting = job.page + 1, false
      end
    elseif GetTime() - job.sentAt > TIMEOUT then
      job.waiting = false
    end
  else
    Send()
  end
end)

function Q.Search(itemID, name, cb)
  name = name or (itemID and C_Item.GetItemNameByID(itemID))
  if not name then return false end
  queue[#queue + 1] = { itemID = itemID, name = name, page = 0, auctions = {}, cb = cb }
  return true
end

function Q.LoadPage(itemID, name, page, cb)
  queue[#queue + 1] = { itemID = itemID, name = name, page = page or 0, auctions = {}, cb = cb, single = true }
end

function Q.Busy() return job ~= nil or #queue > 0 end
function Q.Pending() return #queue + (job and 1 or 0) end
function Q.Clear() queue = {}; job = nil end

-- Auctionator's full scan takes the auction house for itself: wait for it
local function WatchAuctionator()
  local bus = Auctionator and Auctionator.EventBus
  local ev = Auctionator and Auctionator.FullScan and Auctionator.FullScan.Events
  if not (bus and ev and ev.ScanStart) then return end
  pcall(bus.Register, bus, { ReceiveEvent = function(_, name)
    if name == ev.ScanStart then auctionatorScanning = true
    elseif name == ev.ScanComplete or name == ev.ScanFailed then auctionatorScanning = false end
  end }, { ev.ScanStart, ev.ScanComplete, ev.ScanFailed })
end
local w = CreateFrame("Frame")
w:RegisterEvent("PLAYER_LOGIN")
w:SetScript("OnEvent", WatchAuctionator)
