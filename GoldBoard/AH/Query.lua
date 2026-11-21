-- Auction house searches, one item at a time, in a queue. This client (WoW Forever, Interface 16001)
-- has the modern auction house: AuctionHouseFrame and C_AuctionHouse, searched by item, with separate
-- results for commodities (stackable goods, bought by quantity) and items (bought one auction at a time).
-- There is no QueryAuctionItems / AuctionFrame here.
--
-- It shares the auction house with Auctionator: a search is only sent while the game's request throttle
-- is ready, and result events are matched on the item we asked for, so somebody else's search is ignored.
--
-- Q.Search(itemID, name, cb)  cb(result) with result = {
--   itemID, name, commodity, auctions = { { unit, count, buyout, auctionID, mine, commodity } } (cheapest
--   first), lowest (cheapest other seller), lowestMine, mineCount, time, failed, error, partial }
--   failed = true (with error, a sentence to show) when the auction house never answered or was closed.
--   partial = true when the game holds only the first part of the listings (the cheapest ones).
--   With no itemID the name is looked up at the auction house first (a browse search) and itemID filled in.
--   Returns false (and never calls cb) when there is neither an item nor a name to search for.
-- Q.Open()       whether the auction house is open (searches only run while it is).
-- Q.Available()  whether this client has the auction house functions Gold Board uses.
-- Q.Frame()      the auction house window (to dock beside), or nil.

local _, GB = ...
local Q = {}
GB.Query = Q

local TIMEOUT = 6          -- no answer this long after sending: send again
local MAX_TRIES = 4        -- sends per search before giving up
local GIVE_UP = 30         -- seconds one search may take in all (waiting for the throttle included)
local SETTLE = 0.2         -- results arrive in bursts: read a moment after the last event
-- the game's own sort orders, as Auctionator asks for them: cheapest first
local COMMODITY_SORT = { sortOrder = 0, reverseSort = false }
local ITEM_SORT = { sortOrder = 4, reverseSort = false }
Q.FAILED = "The auction house didn't answer: try again"
Q.CLOSED = "The auction house closed: search again"
Q.NOT_OPEN = "Open the auction house first"
Q.NO_API = "This game client has no auction house search Gold Board can use"
Q.NOT_FOUND = "Nothing with that name is on the auction house"

local queue, job = {}, nil
Q.cache = {}               -- [itemID] = last result (posting and cancelling reuse it for a few minutes)

local f = CreateFrame("Frame")

function Q.Frame() return AuctionHouseFrame end
-- open = the game said so (AUCTION_HOUSE_SHOW, until AUCTION_HOUSE_CLOSED) or its window is on screen
local opened = false
function Q.Open() return opened or (AuctionHouseFrame ~= nil and AuctionHouseFrame:IsShown()) or false end

local NEEDED = { "MakeItemKey", "GetItemKeyInfo", "SendSearchQuery", "IsThrottledMessageSystemReady",
  "GetNumCommoditySearchResults", "GetCommoditySearchResultInfo", "GetNumItemSearchResults", "GetItemSearchResultInfo" }
function Q.Available()
  if type(C_AuctionHouse) ~= "table" then return false end
  for _, name in ipairs(NEEDED) do
    if type(C_AuctionHouse[name]) ~= "function" then return false, name end
  end
  return true
end

local function Finish(failed, why)
  local r = { itemID = job.itemID, name = job.name, auctions = job.auctions, time = time(), mineCount = 0,
              partial = job.partial, commodity = job.commodity }
  if failed then r.failed, r.error = true, why or Q.FAILED end
  table.sort(r.auctions, function(a, b) return a.unit < b.unit end)
  for _, a in ipairs(r.auctions) do
    if a.mine then
      r.mineCount = r.mineCount + a.count
      r.lowestMine = r.lowestMine or a.unit
    else
      r.lowest = r.lowest or a.unit
    end
  end
  r.match = job.match
  if job.itemID and not r.failed then Q.cache[Q.CacheKey(job.itemID, job.match)] = r end
  local cb = job.cb
  job = nil
  if cb then
    local ok, err = pcall(cb, r)
    if not ok then GB.Report(err, "search result") end   -- never stops the queue
  end
end

-- weapons and armor come in many variants of one item (levels, suffixes): they are searched the way the
-- game's sell tab does, which lists every variant
local function IsEquipment(itemID)
  local classID = C_Item and C_Item.GetItemInfoInstant and select(6, C_Item.GetItemInfoInstant(itemID))
  return classID == 2 or classID == 4
end
Q.IsEquipment = IsEquipment

-- Item keys: the same item when every part is the same (a missing part counts as 0)
local function SameKey(a, b)
  return type(a) == "table" and type(b) == "table" and a.itemID == b.itemID and (a.itemLevel or 0) == (b.itemLevel or 0)
    and (a.itemSuffix or 0) == (b.itemSuffix or 0) and (a.battlePetSpeciesID or 0) == (b.battlePetSpeciesID or 0)
end
Q.SameKey = SameKey
-- whether a results event answers the search for key: the same item, and any part the search named (not 0)
-- the same. The game may fill in the item level of the key it answers for, so a 0 in ours matches anything.
local function AnswersKey(arg, key)
  if type(arg) ~= "table" or type(key) ~= "table" or arg.itemID ~= key.itemID then return false end
  for _, part in ipairs({ "itemLevel", "itemSuffix", "battlePetSpeciesID" }) do
    local want = key[part] or 0
    if want ~= 0 and (arg[part] or 0) ~= want then return false end
  end
  return true
end
Q.AnswersKey = AnswersKey
-- one variant of a piece of gear (its item level and suffix), or nil when the key names no variant
local function Variant(key)
  if type(key) ~= "table" then return nil end
  if (key.itemLevel or 0) == 0 and (key.itemSuffix or 0) == 0 and (key.battlePetSpeciesID or 0) == 0 then return nil end
  return key
end
-- where a result is remembered: by item, or by item and variant when only that variant was priced
function Q.CacheKey(itemID, match)
  if type(match) ~= "table" then return itemID end
  return string.format("%d:%d:%d:%d", itemID, match.itemLevel or 0, match.itemSuffix or 0, match.battlePetSpeciesID or 0)
end

local function Ready()
  return C_AuctionHouse.IsThrottledMessageSystemReady()
end

-- Step 1 for a search typed by name: find which item it is with a browse search
local function SendBrowse()
  if type(C_AuctionHouse.SendBrowseQuery) ~= "function" then Finish(true, Q.NOT_FOUND) return end
  job.tries = job.tries + 1
  job.waiting, job.sentAt, job.readAt = true, GetTime(), nil
  local ok, err = pcall(C_AuctionHouse.SendBrowseQuery, { searchString = job.name, sorts = {}, filters = {}, itemClassFilters = {} })
  if not ok then job.waiting = false; GB.Report(err, "auction search") end
end

-- the browse results name the item: exact name first, else the first that contains what was typed
local function ReadBrowse()
  local results = C_AuctionHouse.GetBrowseResults and C_AuctionHouse.GetBrowseResults() or {}
  local want, loose, pending = job.name:lower(), nil, false
  for _, b in ipairs(results) do
    local info = b.itemKey and C_AuctionHouse.GetItemKeyInfo(b.itemKey)
    if not info then pending = true
    elseif info.itemName then
      local n = info.itemName:lower()
      if n == want then
        job.itemID, job.name = b.itemKey.itemID, info.itemName
        GB.LearnName(info.itemName, job.itemID)
        return true
      elseif not loose and n:find(want, 1, true) then
        loose = { b.itemKey.itemID, info.itemName }
      end
    end
  end
  if pending and GetTime() - job.sentAt < 3 then return nil end   -- names still loading: look again
  if loose then
    job.itemID, job.name = loose[1], loose[2]
    GB.LearnName(job.name, job.itemID)
    return true
  end
  return false
end

-- Step 2: the listings of one item
local function SendSearch()
  -- still waiting for the game to load the item's auction info: asked again later, not every frame
  if job.nextTry and GetTime() < job.nextTry then return end
  job.key = job.key or (IsEquipment(job.itemID) and { itemID = job.itemID, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 }
    or C_AuctionHouse.MakeItemKey(job.itemID))
  -- the game ignores a search for an item whose auction info it hasn't loaded: asking loads it
  local info = C_AuctionHouse.GetItemKeyInfo(C_AuctionHouse.MakeItemKey(job.itemID))
  if not info then
    -- gear is never a commodity: after a few seconds it is searched without waiting any longer
    if not (IsEquipment(job.itemID) and GetTime() - job.since > 3) then
      job.backoff = math.min(2, (job.backoff or 0.125) * 2)      -- 0.25, 0.5, 1, 2, 2... seconds
      job.nextTry = GetTime() + job.backoff                       -- or sooner, when the game says it loaded it
      return
    end
    info = { isCommodity = false }
  end
  job.nextTry = nil
  job.commodity = info.isCommodity and true or false
  job.name = job.name or info.itemName or (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(job.itemID))
  job.tries = job.tries + 1
  job.waiting, job.sentAt, job.readAt, job.answered = true, GetTime(), nil, job.answered
  local send = C_AuctionHouse.SendSearchQuery
  local sort = job.commodity and COMMODITY_SORT or ITEM_SORT
  if not job.commodity and IsEquipment(job.itemID) and C_AuctionHouse.SendSellSearchQuery then send = C_AuctionHouse.SendSellSearchQuery end
  local ok, err = pcall(send, job.key, { sort }, true)
  if not ok then job.waiting = false; GB.Report(err, "auction search") end
end

-- whether the results the game holds are a real answer (it sometimes answers "nothing" first)
local function Valid()
  local A = C_AuctionHouse
  local has, full, quantity
  if job.commodity then
    has = not A.HasSearchResults or A.HasSearchResults(A.MakeItemKey(job.itemID))
    full = not A.HasFullCommoditySearchResults or A.HasFullCommoditySearchResults(job.itemID)
    quantity = A.GetCommoditySearchResultsQuantity and A.GetCommoditySearchResultsQuantity(job.itemID) or 1
  else
    has = not A.HasSearchResults or A.HasSearchResults(job.key)
    full = not A.HasFullItemSearchResults or A.HasFullItemSearchResults(job.key)
    quantity = A.GetItemSearchResultsQuantity and A.GetItemSearchResultsQuantity(job.key) or 1
  end
  job.partial = not full or nil
  if has then return not (not full and quantity == 0) end
  -- No results held. On this auction house that is also how an item nobody sells is answered, and this
  -- is our own answer (it came after we asked). With the game saying the list is complete, or the same
  -- empty answer twice, nobody sells it: a real, empty answer. Results there but "none held" are asked again.
  local num
  if job.commodity then num = A.GetNumCommoditySearchResults(job.itemID) else num = A.GetNumItemSearchResults(job.key) end
  if (num or 0) > 0 then return false end
  job.empties = (job.empties or 0) + 1
  if full or job.empties >= 2 then job.partial = nil; return true end
  return false
end

local function ReadResults()
  local A = C_AuctionHouse
  job.auctions = {}
  if job.commodity then
    for i = 1, A.GetNumCommoditySearchResults(job.itemID) or 0 do
      local r = A.GetCommoditySearchResultInfo(job.itemID, i)
      if r and r.unitPrice and r.unitPrice > 0 and r.quantity and r.quantity > 0 then
        local mine = r.containsOwnerItem or (r.owners and r.owners[1] == "player") or false
        job.auctions[#job.auctions + 1] = { unit = r.unitPrice, count = r.quantity, buyout = r.unitPrice * r.quantity,
          auctionID = r.auctionID, mine = mine, account = r.containsAccountItem, commodity = true }
      end
    end
  else
    for i = 1, A.GetNumItemSearchResults(job.key) or 0 do
      local r = A.GetItemSearchResultInfo(job.key, i)
      -- auctions with a buyout only: a bid-only auction can't be bought now. Gear comes back in every
      -- variant: a search for one variant (the piece in your bags, or your auction) keeps only that one.
      if r and r.buyoutAmount and r.buyoutAmount > 0 and not (job.match and r.itemKey and not SameKey(r.itemKey, job.match)) then
        -- buyoutAmount buys one; quantity is how many identical ones that row holds
        local count = (r.quantity and r.quantity > 0) and r.quantity or 1
        local mine = r.containsOwnerItem or (r.owners and r.owners[1] == "player") or false
        local k = r.itemKey
        job.auctions[#job.auctions + 1] = { unit = r.buyoutAmount, count = count, buyout = r.buyoutAmount,
          auctionID = r.auctionID, mine = mine, account = r.containsAccountItem, itemLink = r.itemLink, commodity = false,
          variant = Variant(k) and string.format("%d:%d:%d", k.itemLevel or 0, k.itemSuffix or 0, k.battlePetSpeciesID or 0) or nil }
      end
    end
  end
end

-- the auction house opening is told two ways on this client (Auctionator listens to the second)
for _, e in ipairs({ "AUCTION_HOUSE_SHOW", "PLAYER_INTERACTION_MANAGER_FRAME_SHOW", "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" }) do
  pcall(f.RegisterEvent, f, e)
end
f:RegisterEvent("AUCTION_HOUSE_CLOSED")
f:RegisterEvent("COMMODITY_SEARCH_RESULTS_UPDATED")
f:RegisterEvent("ITEM_SEARCH_RESULTS_UPDATED")
f:RegisterEvent("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
f:RegisterEvent("AUCTION_HOUSE_BROWSE_FAILURE")
pcall(f.RegisterEvent, f, "ITEM_KEY_ITEM_INFO_RECEIVED")
f:SetScript("OnEvent", function(_, event, arg)
  if event == "ITEM_KEY_ITEM_INFO_RECEIVED" then
    if job and job.itemID == arg then job.nextTry = nil end    -- loaded: the search can go now
    return
  end
  local auctioneer = (Enum and Enum.PlayerInteractionType and Enum.PlayerInteractionType.Auctioneer)
  if event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" or event == "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" then
    if auctioneer == nil or arg ~= auctioneer then return end
    event = event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" and "AUCTION_HOUSE_SHOW" or "AUCTION_HOUSE_CLOSED"
  end
  if event == "AUCTION_HOUSE_SHOW" then
    opened = true
  elseif event == "AUCTION_HOUSE_CLOSED" then
    opened = false
    -- every search still waiting is told so (its window shows "search again" instead of "Searching..." for ever)
    local waiting = queue
    queue = {}
    if job then Finish(true, Q.CLOSED) end
    for _, j in ipairs(waiting) do
      job = j
      Finish(true, Q.CLOSED)
    end
    job = nil
  elseif not (job and job.waiting) then
    return
  elseif not job.itemID then
    -- looking a name up: any browse answer while we wait is taken as ours
    if event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" then job.readAt = GetTime() + SETTLE
    elseif event == "AUCTION_HOUSE_BROWSE_FAILURE" then job.waiting = false end
  elseif event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
    -- only the answer for the item we asked about (Auctionator's searches fire the same events)
    if job.commodity and arg == job.itemID then job.readAt = GetTime() + SETTLE end
  elseif event == "ITEM_SEARCH_RESULTS_UPDATED" then
    if not job.commodity and AnswersKey(arg, job.key) then job.readAt = GetTime() + SETTLE end
  end
end)

local function Start()
  job.tries, job.since, job.waiting, job.auctions = 0, GetTime(), false, {}
end

-- one step of the current search (made once here, not a new function every frame)
local function Step()
  if job.waiting and job.readAt and GetTime() >= job.readAt then
    if not job.itemID then
      local found = ReadBrowse()
      if found == true then job.waiting, job.tries = false, 0         -- now search that item
      elseif found == false then Finish(true, Q.NOT_FOUND)
      else job.readAt = GetTime() + SETTLE end
    elseif Valid() then
      ReadResults()
      Finish()
    elseif job.tries >= MAX_TRIES then
      -- it never gave a real answer: that is a failure, not "nobody sells it" (which is a real, empty answer)
      Finish(true)
    else
      job.waiting = false    -- an empty first answer: ask again
    end
  elseif job.waiting and GetTime() - job.sentAt > TIMEOUT then
    job.waiting = false
  end
  if job and not job.waiting then
    if GetTime() - job.since > GIVE_UP then Finish(true)
    elseif not Q.Open() then return     -- wait for the auction house (until GIVE_UP)
    elseif not Q.Available() then Finish(true, Q.NO_API)
    elseif job.tries >= MAX_TRIES then Finish(true)
    elseif Ready() then
      if job.itemID then SendSearch() else SendBrowse() end
    end
  end
end

f:SetScript("OnUpdate", function()
  if not job and #queue > 0 then
    job = table.remove(queue, 1)
    Start()
  end
  if not job then return end
  local ok, err = pcall(Step)
  if not ok then
    GB.Report(err, "auction search")
    if job then Finish(true, Q.FAILED) end
  end
end)

-- match: an item key (from the bag item or your auction) to price only that variant of a piece of gear
function Q.Search(itemID, name, cb, match)
  if not itemID and not (name and name ~= "") then return false end
  queue[#queue + 1] = { itemID = itemID, name = name, cb = cb, auctions = {}, match = itemID and type(match) == "table" and match or nil }
  return true
end

function Q.Busy() return job ~= nil or #queue > 0 end
function Q.Pending() return #queue + (job and 1 or 0) end
function Q.Clear() queue = {}; job = nil end
-- after you buy or post an item its remembered listings are out of date (every variant of it)
function Q.Forget(itemID)
  if not itemID then return end
  for k, r in pairs(Q.cache) do
    if k == itemID or (type(r) == "table" and r.itemID == itemID) then Q.cache[k] = nil end
  end
end
