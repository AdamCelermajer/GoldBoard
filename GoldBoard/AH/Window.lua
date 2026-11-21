-- The Gold Board window beside the auction house: Shop, Sell and Cancel.
-- Built for this client's modern auction house (AuctionHouseFrame, C_AuctionHouse): commodities are
-- bought by quantity from the cheapest up, items one auction at a time; posting takes a bag slot.
-- Every buy, post and cancel is one click of yours (the game requires it); the window does the
-- searching, pricing and finding.

local _, GB = ...
local UI = GB.UI
local W = {}
GB.AHWindow = W

local WIDTH, HEIGHT = 700, 500
local PAD = UI.PAD
local win, tabs, views = nil, nil, {}

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

-- an item's name, by whichever of the game's lookups this client has (nil while it isn't loaded yet)
local function ItemName(id)
  local n
  if C_Item and C_Item.GetItemNameByID then n = C_Item.GetItemNameByID(id) end
  if not n then
    local info = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    if info then n = info(id) end
  end
  if not n and C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(id) end
  return n
end

-- an error message without the file and line in front, short enough for a status line
local function Short(err)
  return (tostring(err):gsub("^[^:]*:%d+: ", ""))
end

-- a bag slot the way the auction house functions want it
local function Location(slot)
  if ItemLocation and ItemLocation.CreateFromBagAndSlot then return ItemLocation:CreateFromBagAndSlot(slot.bag, slot.slot) end
  return { bagID = slot.bag, slotIndex = slot.slot }
end

-- a piece of gear's own variant (item level, suffix), so it is priced against the same variant only;
-- a plain piece (level and suffix 0) too, so it isn't priced against "of the Tiger" ones
local function GearKey(itemID, slot)
  if not (GB.Query.IsEquipment(itemID) and C_AuctionHouse and C_AuctionHouse.GetItemKeyFromItem) then return nil end
  local ok, key = pcall(C_AuctionHouse.GetItemKeyFromItem, Location(slot))
  if ok and type(key) == "table" and key.itemID == itemID then return key end
end

-- bags: key -> { itemID, count, free, slots = { {bag, slot, count, locked} }, match } for items you could sell
-- (free: how many of them are in slots that aren't locked).
-- The key is the itemID, or for gear "itemID:level:suffix" with match = its item key (one row per variant).
-- A locked slot (picked up, or selected in another addon's sell tab) is kept but marked: it can't be posted.
-- (bag 0 is the backpack, then the equipped bags and, where there is one, the reagent bag)
local function BagItems()
  local out = {}
  local slots = C_Container and C_Container.GetContainerNumSlots or GetContainerNumSlots
  local item = C_Container and C_Container.GetContainerItemInfo
  if not (slots and item) then error("this game client has no bag functions Gold Board knows", 0) end
  for bag = 0, (NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4) do
    for slot = 1, slots(bag) or 0 do
      local info = item(bag, slot)
      if info and info.itemID and not info.isBound then
        local s = { bag = bag, slot = slot, count = info.stackCount or 1, locked = info.isLocked and true or false }
        local match = GearKey(info.itemID, s)
        local key = match and string.format("%d:%d:%d", info.itemID, match.itemLevel or 0, match.itemSuffix or 0) or info.itemID
        local e = out[key] or { itemID = info.itemID, count = 0, free = 0, slots = {}, match = match }
        e.count = e.count + s.count
        if not s.locked then e.free = e.free + s.count end
        e.slots[#e.slots + 1] = s
        out[key] = e
      end
    end
  end
  return out
end

-- the slot a post is made from: the biggest stack that isn't locked (nil when every one is)
local function PostSlot(b)
  local best
  for _, s in ipairs(b.slots) do
    local locked = s.locked
    if not locked and C_Item and C_Item.IsLocked then
      local ok, l = pcall(C_Item.IsLocked, Location(s))
      locked = ok and l and true or false
    end
    if not locked and (not best or s.count > best.count) then best = s end
  end
  return best
end
local LOCKED = "the item is locked (selected in another addon?): free it there, then click Post again"

-- The game drops a request sent while its auction house throttle is busy, without a word (Auctionator
-- keeps its Post button off for the same reason): nothing is sent until it is ready.
local function Throttled()
  local ready = C_AuctionHouse and C_AuctionHouse.IsThrottledMessageSystemReady
  return ready ~= nil and not ready()
end
local BUSY = "The auction house is busy: click again in a moment."

local COMMODITY = Enum and Enum.ItemCommodityStatus and Enum.ItemCommodityStatus.Commodity or 2

-- the small line at the top right of a tab; tone "error" turns it red, "good" green
local function Status(view, text, tone)
  view.status:SetText(text or "")
  view.status:SetTextColor(unpack(tone == "error" and UI.C.sell or tone == "good" and UI.C.buy or UI.C.muted))
end

-- searches only run at the auction house: say so at once instead of waiting for a timeout
local function NeedAuctionHouse(view)
  if GB.Query.Open() then return true end
  Status(view, GB.Query.NOT_OPEN, "error")
  return false
end

---------------------------------------------------------------------------
-- Shop: deals at your auction house, any item's listings, buy the one you pick
---------------------------------------------------------------------------

local function BuildShop(p)
  local v = CreateFrame("Frame", nil, p)
  v:SetAllPoints()
  v.search = UI.Input(v, 250, "Search an item by its name")
  v.search:SetPoint("TOPLEFT", PAD, -12)
  v.go = UI.Button(v, "Search", 80, 26)
  v.go:SetPoint("LEFT", v.search, "RIGHT", 6, 0)
  v.status = UI.Text(v, 12, "muted", "RIGHT")
  v.status:SetPoint("TOPRIGHT", -PAD, -19)
  v.status:SetWidth(WIDTH - 2 * PAD - 250 - 6 - 80 - 12)

  v.title = UI.Text(v, 16, "ink", "LEFT", UI.FONT_TITLE)
  v.title:SetPoint("TOPLEFT", PAD, -52)
  v.title:SetWidth(WIDTH - 2 * PAD)
  v.sub = UI.Text(v, 12, "muted")
  v.sub:SetPoint("TOPLEFT", PAD, -74)
  v.sub:SetWidth(WIDTH - 2 * PAD)

  -- deals: listed under your buy-below price
  v.deals = UI.Table(v, {
    { key = "name", label = "Item", width = 0, render = function(d) return UI.ItemText(d.itemID, d.name) end },
    { key = "cheapest", label = "Cheapest", width = 92, align = "RIGHT", render = function(d) return UI.Money(d.cheapest) end },
    { key = "buyBelow", label = "Buy below", width = 92, align = "RIGHT", render = function(d) return UI.Color("muted", UI.Money(d.buyBelow)) end },
    { key = "profit", label = "Profit each", width = 96, align = "RIGHT", render = function(d) return UI.Color("buy", UI.Money(d.profit, { sign = true })) end },
    { key = "margin", label = "Margin", width = 62, align = "RIGHT", render = function(d) return UI.Color("buy", UI.Pct(d.margin)) end },
    { key = "sold", label = "Sold/day", width = 64, align = "RIGHT", render = function(d) return d.sold and string.format("%.0f", d.sold) or "-" end },
  }, { sortKey = "score", sortDir = -1,
       onClick = function(_, d)
         local ok, err = pcall(W.OpenItem, d.itemID)
         if not ok then
           Status(v, "That failed: " .. Short(err), "error")
           GB.Report(err, "deal listings")
         end
       end,
       onEnter = function(row, d) UI.ItemTooltip(row, d.itemID) end })
  v.deals:SetPoint("TOPLEFT", PAD - 2, -96); v.deals:SetPoint("BOTTOMRIGHT", -(PAD - 2), 54)

  -- one item's listings, grouped by price and stack size
  v.list = UI.Table(v, {
    { key = "unit", label = "Price each", width = 110, align = "RIGHT", render = function(d)
        local t = UI.Money(d.unit)
        if v.item and v.item.buyBelow and d.unit <= v.item.buyBelow then t = UI.Color("buy", t) end
        return t end },
    { key = "count", label = "Quantity", width = 70, align = "RIGHT" },
    { key = "n", label = "Auctions", width = 72, align = "RIGHT" },
    { key = "buyout", label = "To buy", width = 112, align = "RIGHT", render = function(d)
        return v.item and v.item.commodity and UI.Money(d.buyout) or (UI.Money(d.buyout) .. UI.Color("muted", " for 1")) end },
    { key = "vs", label = "vs usual price", width = 0, align = "RIGHT", render = function(d)
        if not d.vs then return UI.Color("faint", "-") end
        local s = UI.Pct(d.vs - 1)
        return d.vs <= 0.85 and UI.Color("buy", s) or d.vs > 1 and UI.Color("sell", s) or s end },
    { key = "mine", label = "", width = 48, sort = false, render = function(d) return d.mine and UI.Color("gold", "yours") or "" end },
  }, { sortKey = "unit", sortDir = 1, onClick = function(_, d) W.SelectListing(d) end })
  v.list:SetPoint("TOPLEFT", PAD - 2, -96); v.list:SetPoint("BOTTOMRIGHT", -(PAD - 2), 54)
  v.list:Hide()

  v.buy = UI.Button(v, "Buy", 250, 30, "primary")
  v.buy:SetPoint("BOTTOMRIGHT", -(PAD - 2), 12)
  v.buy:Disable()
  v.buy:SetAction(function() return W.PrepareBuy() end, "buying")
  v.back = UI.Button(v, "Back to deals", 120, 30, "quiet")
  v.back:SetPoint("BOTTOMLEFT", PAD - 2, 12)
  v.back:SetScript("OnClick", function() W.ShowDeals() end)
  v.note = UI.Text(v, 12, "muted")
  v.note:SetPoint("LEFT", v.back, "RIGHT", 10, 0)
  v.note:SetPoint("RIGHT", v.buy, "LEFT", -10, 0)

  local function DoSearch()
    Status(v, "")
    local text = strtrim(v.search:GetText() or "")
    v.search:ClearFocus()
    if text == "" then return end
    local id = GB.IDFromName(text)
    W.OpenItem(id, id and ItemName(id) or text)
  end
  v.search:SetScript("OnEnterPressed", DoSearch)
  v.go:SetScript("OnClick", DoSearch)
  return v
end

-- a commodity purchase waiting for your confirm click is dropped when you look at something else
local function DropQuote(v)
  if v.quote then
    v.quote = nil
    if C_AuctionHouse and C_AuctionHouse.CancelCommoditiesPurchase then pcall(C_AuctionHouse.CancelCommoditiesPurchase) end
  end
end

-- the watchers of a purchase in progress (defined with the purchases below)
local buyWatch, bidWatch = CreateFrame("Frame"), CreateFrame("Frame")
-- looking at something else: a quote waiting for its confirm is dropped, and a buy still waiting for the
-- game's answer no longer touches the screen (its own answer is still written in the ledger)
local function LeaveBuy(v)
  DropQuote(v)
  buyWatch:UnregisterAllEvents(); buyWatch.deadline, buyWatch.call = nil, nil
  bidWatch:UnregisterAllEvents(); bidWatch.w = nil
  v.buying = false
end

function W.ShowDeals()
  local v = views.shop
  LeaveBuy(v)
  v.item, v.selected, v.result = nil, nil, nil
  v.list:Hide(); v.deals:Show(); v.back:Hide()
  v.buy:SetLabel("Pick a deal to see its listings"); v.buy:Disable()
  local list = GB.Pricing.Deals()
  local meta = GB.Signals.Meta()
  v.title:SetText(UI.Color("gold", #list .. (#list == 1 and " deal" or " deals")) .. " on " .. (meta.label or GB.AH()))
  v.sub:SetText("Listed under the buy-below price at the last look (Auctionator's scan or the TSM update, whichever is newer).")
  v.note:SetText("Click a deal for its live listings.")
  if not meta.count or meta.count == 0 then
    v.deals:SetData(list, "No prices yet. Start the Gold Board on your PC, let it fetch the TSM prices, then /reload.")
  else
    v.deals:SetData(list, "No deals right now. They show up after Auctionator's next scan or the next TSM update.")
  end
  Status(v, "")
  GB.Pricing.FillNames(list, function() if v.deals:IsShown() then v.deals:Refresh() end end)
end

-- title and price line for the item the listings belong to
local function ShowItemHead(v)
  local it = v.item
  local s = it.itemID and GB.Signals.Get(it.itemID)
  it.sell, it.buyBelow = s and s.sell, s and s.buyBelow
  v.title:SetText(it.itemID and UI.ItemText(it.itemID, it.name) or it.name)
  if s then
    local when = GB.Pricing.BuyTiming(s)
    v.sub:SetText("Usually sells for " .. UI.Money(s.sell) .. "   Buy below " .. UI.Color("buy", UI.Money(s.buyBelow))
      .. (s.soldPerDay and string.format("   About %.0f sold a day", s.soldPerDay) or "")
      .. (when and ("   " .. when:gsub("^%l", string.upper)) or ""))
  else
    v.sub:SetText("The Gold Board has no price for this item yet, so nothing says whether it's cheap.")
  end
end

function W.OpenItem(itemID, name)
  local v = views.shop
  name = name or (itemID and ItemName(itemID))
  if not name then Status(v, "The game hasn't loaded that item yet: try again.", "error") return end
  if not NeedAuctionHouse(v) then return end
  LeaveBuy(v)
  v.deals:Hide(); v.list:Show(); v.back:Show()
  v.item = { itemID = itemID, name = name }
  v.selected, v.result = nil, nil
  v.list.selected = nil
  v.buy:SetLabel("Pick a listing to buy"); v.buy:Disable()
  v.note:SetText("")
  ShowItemHead(v)
  v.list:SetData({}, "Searching the auction house...")
  Status(v, "searching...")
  local asked = {}
  v.item.asked = asked
  if not GB.Query.Search(itemID, name, function(r) r.asked = asked; W.ShowListings(r) end) then
    v.list:SetData({}, "Item not found: type its exact name.", "error")
    Status(v, "")
  end
end

function W.ShowListings(r)
  local v = views.shop
  if not v.item then return end
  -- the answer to the item on screen (a search typed by name comes back with the item's real name)
  if v.item.itemID then
    if r.itemID ~= v.item.itemID then return end
  elseif v.item.asked ~= r.asked then return end
  if r.failed then
    v.list:SetData({}, r.error, "error")
    Status(v, "no answer", "error")
    return
  end
  -- a search typed by name now knows which item it is: its prices can be shown
  if not v.item.itemID and r.itemID then
    v.item.itemID, v.item.name = r.itemID, r.name or v.item.name
    ShowItemHead(v)
  end
  v.item.commodity = r.commodity
  v.result = r
  local groups, byKey = {}, {}
  for _, a in ipairs(r.auctions) do
    -- commodities come one row per price already; items are grouped by price (and by variant: gear of
    -- different item levels or suffixes is never one row)
    local key = a.unit .. (a.mine and "m" or "") .. (a.variant and ("v" .. a.variant) or "")
    local g = byKey[key]
    if not g then
      g = { unit = a.unit, count = a.count, buyout = a.buyout, n = 0, auctions = {}, mine = a.mine,
            vs = v.item.sell and a.unit / v.item.sell or nil }
      byKey[key] = g
      groups[#groups + 1] = g
    end
    g.n = g.n + 1
    g.auctions[#g.auctions + 1] = a
    if g.n > 1 then
      g.count = g.count + a.count
      if r.commodity then g.buyout = g.buyout + a.buyout end   -- an item row's price buys one of them
    end
  end
  v.list:SetData(groups, "Nobody is selling it right now.")
  Status(v, #r.auctions .. (r.partial and "+ listings, the cheapest shown" or (#r.auctions == 1 and " listing" or " listings")))
  -- what a purchase just said ("Bought 45 for ...") stays until you pick something else
  v.note:SetText(v.item.keepNote or (#groups == 0 and "" or r.commodity and "Pick a price: you buy everything up to it, cheapest first."
    or "Green prices are under your buy-below price."))
end

-- Pick a listing. An item auction is bought as it is. A commodity is bought by quantity from the cheapest
-- up, so picking a price means "everything listed up to this price".
function W.SelectListing(g)
  local v = views.shop
  if not v.item then return end
  if v.buying then return end      -- a purchase is waiting for the game: picking another row mustn't drop it
  DropQuote(v)
  v.item.keepNote = nil
  v.selected = g
  v.list:Select(g)
  if g.mine then v.buy:SetLabel("That's your own auction"); v.buy:Disable() return end
  if g.n <= 0 or not g.auctions[1] then v.buy:SetLabel("Gone: search again"); v.buy:Disable() return end
  if v.item.commodity then
    local qty, total, cheaper, same = 0, 0, nil, false
    for _, x in ipairs(v.list.data) do
      if not x.mine and x.unit <= g.unit then qty, total = qty + x.count, total + x.buyout end
      if x.mine and x.unit < g.unit and (not cheaper or x.unit < cheaper) then cheaper = x.unit end
      if x.mine and x.unit == g.unit then same = true end
    end
    -- A commodity is bought cheapest first. Your own listing (the rows the game marks as containing yours)
    -- cheaper than the price picked would be part of that purchase, so only prices under it are bought.
    -- At the same price it may or may not be: that is said, not refused.
    if cheaper then
      v.buy:SetLabel("Your own listing is cheaper"); v.buy:Disable()
      v.note:SetText(UI.Color("sell", "You have some listed at " .. UI.Money(cheaper) .. ", under this price: buying up to here would take yours first. Pick a price under " .. UI.Money(cheaper) .. ", or cancel yours."))
      return
    end
    g.buyQty, g.buyTotal = qty, total
    v.buy:SetLabel(string.format("Buy %d for about %s", qty, UI.Money(total)))
    v.note:SetText(same and UI.Color("gold", "You also have some listed at this price: the game may count yours among the cheapest. It confirms the exact price first.")
      or ("Everything listed up to " .. UI.Money(g.unit) .. " each. The game confirms the exact price first."))
  else
    v.buy:SetLabel(string.format("Buy 1 for %s", UI.Money(g.unit)))
    v.note:SetText(g.count > 1 and (g.count .. " at this price: one per click") or "")
  end
  v.buy:Enable()
end

-- drop one auction of a group (the one bought); the row goes when none are left
local function TakeOne(v, g, a)
  for i, x in ipairs(g.auctions) do if x == a then table.remove(g.auctions, i) break end end
  g.n = g.n - 1
  g.count = math.max(0, g.count - (a and a.count or 1))
  if g.n <= 0 then
    for gi, x in ipairs(v.list.data) do if x == g then table.remove(v.list.data, gi) break end end
    v.selected, v.list.selected = nil, nil
  end
  v.list:Refresh()
end

-- Commodity purchases take two steps (the game's rule): ask for the price of a quantity, then confirm it.
local COMMODITY_EVENTS = { "COMMODITY_PRICE_UPDATED", "COMMODITY_PRICE_UNAVAILABLE", "COMMODITY_PURCHASE_SUCCEEDED", "COMMODITY_PURCHASE_FAILED" }
local function EndCommodity(v, note, tone)
  buyWatch:UnregisterAllEvents()
  buyWatch.deadline, buyWatch.call = nil, nil
  v.buying = false
  if note then v.note:SetText(tone and UI.Color(tone, note) or note) end
end
-- the listings changed: show them again, keeping what the purchase said under them
local function LookAgain(v, itemID, note)
  GB.Query.Forget(itemID)
  if v.item and v.item.itemID == itemID then
    W.OpenItem(itemID, v.item.name)
    if v.item then v.item.keepNote = note end
    v.note:SetText(note)
  end
end
buyWatch:SetScript("OnEvent", GB.Safe(function(_, event, unit, total)
  local v = views.shop
  local q = v.quote
  if not q then EndCommodity(v) return end
  if event == "COMMODITY_PRICE_UPDATED" and not q.confirmed then
    buyWatch.deadline = nil
    v.buying = false
    if total > (GetMoney() or 0) then
      DropQuote(v)
      EndCommodity(v, "You don't have enough gold for " .. q.qty .. " (" .. UI.Money(total) .. ").", "sell")
      v.buy:SetLabel("Not enough gold"); v.buy:Disable()
      return
    end
    q.total, q.unit = total, unit
    v.buy:SetLabel(string.format("Confirm: %d for %s", q.qty, UI.Money(total)))
    v.buy:Enable()
    v.note:SetText("That is " .. UI.Money(unit) .. " each. Click again to buy.")
  elseif event == "COMMODITY_PRICE_UNAVAILABLE" then
    DropQuote(v)
    EndCommodity(v, "The game couldn't price that: somebody bought some. Search again.", "sell")
    v.buy:SetLabel("Search again"); v.buy:Disable()
  elseif event == "COMMODITY_PURCHASE_SUCCEEDED" or event == "COMMODITY_PURCHASE_FAILED" then
    local ok = event == "COMMODITY_PURCHASE_SUCCEEDED"
    v.quote = nil
    EndCommodity(v)
    LookAgain(v, q.itemID, ok and UI.Color("buy", "Bought " .. q.qty .. " for " .. UI.Money(q.total) .. ".")
      or UI.Color("sell", "The purchase failed: nothing was bought."))
  end
end, "commodity purchase"))
buyWatch:SetScript("OnUpdate", GB.Safe(function()
  local v = views.shop
  -- the call never came back (a Lua error inside it): nothing to wait for
  if buyWatch.call and not buyWatch.call.back then
    DropQuote(v)
    EndCommodity(v, "The purchase call failed with an error: nothing was bought.", "sell")
    if v.selected then W.SelectListing(v.selected) end
    return
  end
  if buyWatch.deadline and GetTime() > buyWatch.deadline then
    local q = v.quote
    if q and q.confirmed then
      -- confirmed but never answered: it may well have gone through, so look again instead of saying it failed
      v.quote = nil
      EndCommodity(v)
      LookAgain(v, q.itemID, UI.Color("gold", "The auction house didn't confirm the purchase: check your gold and your mail."))
    else
      DropQuote(v)
      EndCommodity(v, "No price from the auction house: try again.", "sell")
      if v.selected then W.SelectListing(v.selected) end
    end
  end
end, "commodity purchase"))

-- An item auction is bought with one bid; the list only changes once the game says it went through
-- (or why it didn't).
local BID_EVENTS = { "AUCTION_HOUSE_PURCHASE_COMPLETED", "AUCTION_HOUSE_SHOW_ERROR", "UI_ERROR_MESSAGE" }
local BID_WAIT = 10
local function EndBid(ok, why)
  local w = bidWatch.w
  bidWatch:UnregisterAllEvents()
  bidWatch.w = nil
  if not w then return end
  local v = views.shop
  v.buying = false
  if ok then GB.Query.Forget(w.itemID) end
  if v.item ~= w.item then return end       -- you've moved on: nothing on screen is about this buy
  if ok and (w.a.count or 1) > 1 then
    -- that auction is gone with its id: what is left at this price is only known by looking again
    LookAgain(v, w.itemID, UI.Color("buy", "Bought for " .. UI.Money(w.a.unit) .. "."))
  elseif ok then
    TakeOne(v, w.g, w.a)
    if v.selected == w.g and w.g.n > 0 then
      W.SelectListing(w.g)
      v.note:SetText(UI.Color("buy", "Bought for " .. UI.Money(w.a.unit) .. ". ") .. w.g.count .. " left at this price")
    else
      v.buy:SetLabel("Pick a listing to buy"); v.buy:Disable()
      v.note:SetText(UI.Color("buy", "Bought for " .. UI.Money(w.a.unit) .. "."))
    end
  elseif why == nil then
    -- no answer at all: it may have gone through, so the listings are looked at again
    LookAgain(v, w.itemID, UI.Color("gold", "The auction house didn't confirm the purchase: check your gold and your mail."))
  else
    if v.selected then W.SelectListing(v.selected) end
    v.note:SetText(UI.Color("sell", "Not bought: " .. why))
  end
end
bidWatch:SetScript("OnEvent", GB.Safe(function(_, event, a1, a2)
  local w = bidWatch.w
  if not w then return end
  if event == "AUCTION_HOUSE_PURCHASE_COMPLETED" then
    if a1 == nil or a1 == w.auctionID then EndBid(true) end
  elseif event == "AUCTION_HOUSE_SHOW_ERROR" then
    -- the game's own auction house error; its text usually follows as a red message
    w.lastError = w.lastError or ("auction house error " .. tostring(a1))
    w.failAt = w.failAt or (GetTime() + 0.5)
  elseif event == "UI_ERROR_MESSAGE" then
    local text = type(a2) == "string" and a2 or (type(a1) == "string" and a1) or nil
    if text and (text == ERR_NOT_ENOUGH_MONEY or text:lower():find("auction")) then
      w.lastError = text
      w.failAt = GetTime()
    end
  end
end, "buying"))
bidWatch:SetScript("OnUpdate", GB.Safe(function()
  local w = bidWatch.w
  if not w then return end
  if w.call and not w.call.back then EndBid(false, "the purchase call failed with an error") return end
  local now = GetTime()
  if w.failAt and now >= w.failAt then EndBid(false, w.lastError)
  elseif now > w.deadline then EndBid(false, nil) end
end, "buying"))

-- What the Buy click should do: returns the one game call to make, what follows it, its description and
-- what is set up just before it (nil = nothing to send).
function W.PrepareBuy()
  local v = views.shop
  local g = v.selected
  if not g or not v.item or v.buying then return end
  if not NeedAuctionHouse(v) then return end
  local A = C_AuctionHouse
  if Throttled() then v.note:SetText(UI.Color("sell", BUSY)) return end
  if v.item.commodity then
    local q = v.quote
    if q and q.total and not q.confirmed then
      -- second click: confirm the price the game quoted
      return function() A.ConfirmCommoditiesPurchase(q.itemID, q.qty) end, function(_, blocked)
        if blocked then
          if v.quote == q then DropQuote(v); EndCommodity(v) end
          v.note:SetText(UI.Color("sell", "Not bought: the game blocked " .. blocked))
          return
        end
        if v.quote ~= q then return end      -- already answered during the call
        v.buy:SetLabel("Buying..."); v.buy:Disable()
      end, string.format("C_AuctionHouse.ConfirmCommoditiesPurchase(item %d, quantity %d)", q.itemID, q.qty),
      function(entry)
        q.confirmed = true
        v.buying = true
        GB.Ledger.ExpectCommodityConfirm(q.itemID, q.qty)
        buyWatch.call = entry
        for _, e in ipairs(COMMODITY_EVENTS) do buyWatch:RegisterEvent(e) end
        buyWatch.deadline = GetTime() + 8
      end
    end
    -- first click: ask what that quantity costs right now
    if not (A.StartCommoditiesPurchase and A.ConfirmCommoditiesPurchase) then
      v.note:SetText(UI.Color("sell", "This client can't buy commodities from here.")) return
    end
    local itemID, qty = v.item.itemID, g.buyQty
    local quote = { itemID = itemID, qty = qty }
    return function() A.StartCommoditiesPurchase(itemID, qty) end, function(_, blocked)
      if blocked then
        if v.quote == quote then DropQuote(v); EndCommodity(v) end
        if v.selected then W.SelectListing(v.selected) end
        v.note:SetText(UI.Color("sell", "Not bought: the game blocked " .. blocked))
        return
      end
      if v.quote ~= quote or quote.total then return end      -- already answered during the call
      v.buy:SetLabel("Getting the price..."); v.buy:Disable()
    end, string.format("C_AuctionHouse.StartCommoditiesPurchase(item %d, quantity %d)", itemID, qty),
    function(entry)
      v.quote = quote
      v.buying = true
      buyWatch.call = entry
      for _, e in ipairs(COMMODITY_EVENTS) do buyWatch:RegisterEvent(e) end
      buyWatch.deadline = GetTime() + 8
    end
  end
  -- an item: buy out this auction
  local a = g.auctions[1]
  if not a then return end
  if (GetMoney() or 0) < a.unit then
    v.note:SetText(UI.Color("sell", "You don't have enough gold for this one."))
    return
  end
  local w = { auctionID = a.auctionID, a = a, g = g, item = v.item, itemID = v.item.itemID }
  return function() A.PlaceBid(a.auctionID, a.unit) end, function(_, blocked)   -- the row's buyout buys one
    if blocked then
      if bidWatch.w == w then bidWatch:UnregisterAllEvents(); bidWatch.w = nil; v.buying = false end
      if v.selected then W.SelectListing(v.selected) end
      v.note:SetText(UI.Color("sell", "Not bought: the game blocked " .. blocked))
      return
    end
    if bidWatch.w ~= w then return end       -- already answered during the call
    -- no second click until the game has answered this one
    v.buy:SetLabel("Buying..."); v.buy:Disable()
  end, string.format("C_AuctionHouse.PlaceBid(auction %s, %d)", tostring(a.auctionID), a.unit),
  function(entry)
    w.call, w.deadline = entry, GetTime() + BID_WAIT
    bidWatch.w = w
    GB.Ledger.ExpectBid(a.auctionID, a.unit)
    v.buying = true
    for _, e in ipairs(BID_EVENTS) do pcall(bidWatch.RegisterEvent, bidWatch, e) end
  end
end

---------------------------------------------------------------------------
-- Sell: what in your bags sells, priced against the live listings, one post per click
---------------------------------------------------------------------------

local function BuildPost(p)
  local v = CreateFrame("Frame", nil, p)
  v:SetAllPoints()
  v.scan = UI.Button(v, "Check my bags", 140, 26)
  v.scan:SetPoint("TOPLEFT", PAD, -12)
  v.summary = UI.Text(v, 13, "ink")
  v.summary:SetPoint("LEFT", v.scan, "RIGHT", 12, 0)
  v.status = UI.Text(v, 12, "muted", "RIGHT")
  v.status:SetPoint("TOPRIGHT", -PAD, -19)
  v.status:SetWidth(250)
  v.info = UI.Note(v, WIDTH - 2 * PAD)
  v.info:SetPoint("TOPLEFT", PAD, -48)
  v.info:SetText("What to sell now, what to hold and when. Prices undercut the cheapest seller and never go under "
    .. GB.Pricing.DEFAULTS.floor .. "% of the usual price. Post works through \"Sell now\" first; click any priced row to post that one.")
  v.table = UI.Table(v, {
    { key = "name", label = "Item", width = 0, render = function(d) return UI.ItemText(d.itemID, d.name) end },
    { key = "have", label = "Have", width = 48, align = "RIGHT" },
    { key = "unit", label = "Price each", width = 92, align = "RIGHT", render = function(d) return d.unit and UI.Money(d.unit) or UI.Color("faint", "-") end },
    { key = "verdict", label = "Verdict", width = 92, sortValue = function(d) return d.rank or 9 end, render = function(d)
        if d.done then return UI.Color(d.doneTone or "muted", d.doneText or "done") end
        return d.verdict or UI.Color("faint", "checking...") end },
    { key = "why", label = "When / why", width = 260, sort = false, render = function(d)
        return UI.Color(d.failed and "sell" or "muted", d.why or "") end },
  }, { sortKey = "sortKey", sortDir = 1, onClick = function(_, d)
         if d.unit and not d.done then views.post.current = d; views.post.table:Select(d); W.UpdatePostButton()
         else views.post.detail:SetText(d.why and (d.name .. ": " .. d.why) or "") end   -- why this one can't be posted
       end,
       onEnter = function(row, d) UI.ItemTooltip(row, d.itemID) end })
  v.table:SetPoint("TOPLEFT", PAD - 2, -88); v.table:SetPoint("BOTTOMRIGHT", -(PAD - 2), 54)
  v.post = UI.Button(v, "Post", 270, 30, "primary")
  v.post:SetPoint("BOTTOMRIGHT", -(PAD - 2), 12)
  v.post:Disable()
  v.skip = UI.Button(v, "Skip", 80, 30, "quiet")
  v.skip:SetPoint("RIGHT", v.post, "LEFT", -6, 0)
  v.skip:Disable()
  -- the chosen row's whole reason, in full (the column may cut it short)
  v.detail = UI.Note(v, WIDTH - 2 * PAD - 270 - 80 - 18)
  v.detail:SetPoint("BOTTOMLEFT", PAD, 14)
  v.detail:SetHeight(30)
  v.scan:SetScript("OnClick", function()
    local ok, err = pcall(W.ScanPost)
    if not ok then
      Status(v, "The check failed: " .. Short(err), "error")
      GB.Report(err, "Check my bags")
    end
  end)
  v.post:SetAction(function() return W.PreparePost() end, "posting")
  v.skip:SetScript("OnClick", function()
    if v.current then v.current.done, v.current.doneText = true, "skipped" end
    W.NextPost()
  end)
  v.table:SetData({}, "Click \"Check my bags\" to see what to sell now and what to hold.")
  return v
end

-- "3 sell now   1 wait   2 hold" above the table: the answer before the details
local function PostSummary()
  local v = views.post
  local n = { 0, 0, 0 }
  for _, d in ipairs(v.table.data) do
    if not d.done and d.rank and d.rank <= 3 then n[d.rank] = n[d.rank] + 1 end
  end
  if #v.table.data == 0 then v.summary:SetText("") return end
  v.summary:SetText(UI.Color("buy", n[1] .. " sell now") .. "    " .. UI.Color("gold", n[2] .. " wait") .. "    "
    .. UI.Color("sell", n[3] .. " hold"))
end

-- a row that couldn't be priced: shown last, never posted
local function Unpriced(row, verdict, why, failed)
  row.rank, row.verdict, row.why, row.unit, row.failed = 5, UI.Color("muted", verdict), why, nil, failed
  row.sortKey = row.rank * 1e12 - row.value
end

-- price one bag row from its live listings r
local function JudgePost(row, r, rules)
  if r.failed then Unpriced(row, "No answer", r.error, true) return end
  row.commodity = r.commodity      -- what the auction house says it is (used when the bag slot can't tell yet)
  local prices = GB.Pricing.Prices(row.itemID)
  local mineLowest = r.lowestMine and (not r.lowest or r.lowestMine <= r.lowest)
  local unit, why = GB.Pricing.PostPrice(prices, r.lowest, mineLowest)
  why = why or ""
  -- the verdict: sell now, wait for its dear hour, or hold (being dumped / already yours cheapest)
  if not unit then
    if why:find("hold") then row.rank, row.verdict = 3, UI.Verdict("sell", "Hold")
    else row.rank, row.verdict = 4, UI.Color("muted", "Leave") end
    row.why = why
  elseif row.timingGood == false then
    row.rank, row.verdict, row.why = 2, UI.Verdict("gold", "Wait"), row.timing
  else
    row.rank, row.verdict = 1, UI.Verdict("buy", "Sell now")
    row.why = row.timing and (why .. "; " .. row.timing) or why
  end
  row.sortKey = row.rank * 1e12 - row.value
  if unit then
    -- all of it that can be posted (a locked stack is left out), in one post
    row.unit, row.qty = math.max(1, math.floor(unit)), row.free or row.have
    if row.qty <= 0 then row.why = LOCKED end
  end
end
W.JudgePost = JudgePost

-- Every item is checked on its own: one that fails is marked and counted in the status line, the rest go on.
function W.ScanPost()
  local v = views.post
  if not NeedAuctionHouse(v) then return end
  v.rechecking, v.recheckOf = false, nil      -- a re-check still on its way belongs to the old list
  local bags = BagItems()
  local rules = GB.Pricing.Rules()
  local rows, pending, failed, firstError = {}, 0, 0, nil
  local function Fail(err)
    failed, firstError = failed + 1, firstError or Short(err)
    GB.Report(err, "Check my bags")   -- the full error, with its file and line, in chat
  end
  local function ShowStatus(first)
    local text = pending > 0 and ("checking " .. pending .. (first and " items..." or " more...")) or (first and "" or "checked " .. UI.Ago(time()))
    if failed > 0 then text = (text ~= "" and (text .. ". ") or "") .. failed .. " failed: " .. firstError end
    Status(v, text, failed > 0 and "error" or nil)
  end
  for bagKey, b in pairs(bags) do
    local itemID = b.itemID
    local ok, err = pcall(function()
      local s = GB.Signals.Get(itemID)
      -- only what the dashboard knows sells (TSM prices and EU sales), so junk and soulbound stay out
      if not (s and s.sell and (s.soldPerDay or 0) >= 0.5) then return end
      local name = ItemName(itemID)
      local row = { itemID = itemID, name = name or ("item " .. itemID), have = b.count, value = s.sell * b.count,
                    bagKey = bagKey, match = b.match, free = b.free }
      row.sortKey = 5 * 1e12 - row.value
      rows[#rows + 1] = row
      row.timing, row.timingGood = GB.Pricing.SellTiming(s)
      -- search by its real name only (the game may not have loaded it yet: then the next check finds it)
      local queued = name and GB.Query.Search(itemID, name, function(r)
        pending = pending - 1
        if v.table.data ~= rows then return end   -- a newer check replaced this one
        local okJudge, judgeErr = pcall(JudgePost, row, r, rules)
        if not okJudge then Fail(judgeErr); Unpriced(row, "Error", "couldn't price it", true) end
        row.checkedAt = GetTime()
        v.table:Refresh()
        PostSummary()
        ShowStatus()
        -- as soon as a row is priced, the first one to sell is picked (unless you picked one already)
        if not v.posting and not v.rechecking and (not v.current or v.current.done or not v.current.unit) then W.NextPost() end
      end, b.match)
      if queued then pending = pending + 1
      else Unpriced(row, "?", "the game hasn't loaded this item yet: check again") end
    end)
    if not ok then Fail(err) end
  end
  v.table.selected = nil
  v.table:SetData(rows, GB.Signals.Meta().count and "Nothing in your bags that the Gold Board knows sells."
    or "No prices yet. Start the Gold Board on your PC, then /reload.")
  ShowStatus(true)
  PostSummary()
  v.current = nil
  W.UpdatePostButton()
end

function W.NextPost()
  local v = views.post
  v.current = nil
  -- next "Sell now" (a "Wait" row is still posted if you click it)
  for _, d in ipairs(v.table.data) do
    if d.unit and not d.done and d.rank == 1 then v.current = d break end
  end
  v.table:Select(v.current)
  PostSummary()
  W.UpdatePostButton()
end

function W.UpdatePostButton()
  local v = views.post
  local d = v.current
  v.detail:SetText(d and d.why and (d.name .. ": " .. d.why) or "")
  if v.posting then v.post:SetLabel("Posting...") v.post:Disable() v.skip:Disable() return end
  if v.rechecking then return end
  if not d then v.post:SetLabel("Nothing to post"); v.post:Disable(); v.skip:Disable() return end
  if (d.qty or 0) <= 0 then v.post:SetLabel("Locked in another addon"); v.post:Disable(); v.skip:Enable() return end
  v.post:SetLabel(string.format("Post %d at %s each", d.qty, UI.Money(d.unit)))
  v.post:Enable()
  v.skip:Enable()
end

-- A post is answered in different ways (and sometimes not at all): the game's "auction created" event, its
-- multi-sell progress, or simply the items leaving your bags. Any of them counts. Where the game wants
-- its own "are you sure?" first, its popup is shown and the post waits for your answer there.
-- Everything is watched from just before the call, so an answer given during the call itself is heard.
local postWatch = CreateFrame("Frame")
local POST_EVENTS = { "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED", "AUCTION_HOUSE_SHOW_ERROR", "AUCTION_HOUSE_AUCTION_CREATED", "AUCTION_MULTISELL_START", "AUCTION_MULTISELL_UPDATE", "AUCTION_MULTISELL_FAILURE",
  "AUCTION_HOUSE_POST_WARNING", "AUCTION_HOUSE_POST_ERROR", "UI_ERROR_MESSAGE", "BAG_UPDATE_DELAYED", "BAG_UPDATE", "OWNED_AUCTIONS_UPDATED" }
local POST_WAIT, CONFIRM_WAIT, MULTISELL_WAIT = 10, 60, 30
local SETTLE, SETTLE_PART = 0.5, 2   -- all of it left the bags: a moment more; only part of it: longer, the rest may follow
local PRICE_AGE = 30   -- a price checked longer ago than this is checked again before posting
local PostFinished   -- below: settles the post on the row, whichever way it ended
local ITEM_STATUS = Enum and Enum.ItemCommodityStatus and Enum.ItemCommodityStatus.Item or 1

-- The market moves between the bag check and the post: look at the listings again and re-price the row.
-- A search can't be followed by a post in the same click (the game wants a click for the post itself),
-- so the button then shows the fresh price and waits for your click.
local function Recheck(d)
  local v = views.post
  local data, token = v.table.data, {}
  v.rechecking, v.recheckOf = true, token
  v.post:SetLabel("Checking the price..."); v.post:Disable(); v.skip:Disable()
  local old = d.unit
  local queued = GB.Query.Search(d.itemID, d.name, function(r)
    if v.recheckOf ~= token then return end       -- a newer check (or closing the window) replaced this one
    v.rechecking, v.recheckOf = false, nil
    if v.table.data ~= data then W.UpdatePostButton() return end   -- the row is from a list no longer shown
    if r.failed then
      Status(v, "Couldn't re-check the price: " .. tostring(r.error), "error")
      W.UpdatePostButton()
      return
    end
    d.verdict, d.why, d.unit, d.rank, d.failed = nil, nil, nil, nil, nil
    local ok, err = pcall(JudgePost, d, r, GB.Pricing.Rules())
    if not ok then GB.Report(err, "re-pricing"); Unpriced(d, "Error", "couldn't price it", true) end
    d.checkedAt = GetTime()
    v.table:Refresh()
    PostSummary()
    if not d.unit then
      Status(v, d.name .. " is no longer worth posting: " .. (d.why or ""), "error")
      W.NextPost()
    else
      v.current = d
      v.table:Select(d)
      W.UpdatePostButton()
      Status(v, d.unit ~= old and ("Price changed: now " .. UI.Money(d.unit) .. " each. Click Post.") or "Price still right: click Post.",
        d.unit ~= old and "error" or "good")
    end
  end, d.match)
  if not queued then v.rechecking, v.recheckOf = false, nil; W.UpdatePostButton() end
end


-- how many of the row's item have left the bags since the post was sent
local function PostedSoFar()
  local now = GB.BagCount(postWatch.row.itemID)
  if not (now and postWatch.before) then return 0 end
  return math.max(0, postWatch.before - now)
end

-- The game's "are you sure?" popup for a post: found when it is shown, so that closing it without
-- confirming releases the post at once (else it is released after CONFIRM_WAIT).
local function PostPopup(which)
  if type(which) ~= "string" or not which:find("AUCTION") then return nil end
  if StaticPopup_FindVisible then
    local f = StaticPopup_FindVisible(which)
    if f then return f end
  end
  for i = 1, (STATICPOPUP_NUMDIALOGS or 4) do
    local f = _G["StaticPopup" .. i]
    if type(f) == "table" and f.IsShown and f:IsShown() and f.which == which then return f end
  end
end
-- whether the popup found is still up (its name is only compared where the frame carries one)
local function PopupUp()
  local f = postWatch.popup
  return f:IsShown() and (not postWatch.popupNamed or f.which == postWatch.popupWhich)
end
local function FindPostPopup()
  for _, which in ipairs({ "AUCTION_HOUSE_POST_WARNING", "AUCTION_HOUSE_POST_ERROR" }) do
    local f = PostPopup(which)
    if f then return f, which end
  end
end
if type(StaticPopup_Show) == "function" then
  hooksecurefunc("StaticPopup_Show", GB.Safe(function(which)
    if postWatch.row and not postWatch.popup then
      local f = PostPopup(which)
      if f then postWatch.popup, postWatch.popupWhich, postWatch.popupNamed = f, which, f.which == which end
    end
  end, "post popup"))
end
local function WaitForPopup(now)
  postWatch.confirm, postWatch.deadline = true, now + CONFIRM_WAIT
  if not postWatch.popup then
    postWatch.popup, postWatch.popupWhich = FindPostPopup()
    postWatch.popupNamed = postWatch.popup ~= nil and postWatch.popup.which == postWatch.popupWhich
  end
  Status(views.post, "The game asks you to confirm this post: answer its popup.")
end

-- What the Post click should do: every check first, then the one game call to make, what follows it, its
-- description, and what is set up just before it.
function W.PreparePost()
  local v = views.post
  local d = v.current
  if not d or v.posting or v.rechecking then return end
  if not NeedAuctionHouse(v) then return end
  local A = C_AuctionHouse
  -- find it in the bags
  local b = BagItems()[d.bagKey or d.itemID]
  if not b then d.done, d.doneText = true, "gone"; d.why = "not in your bags any more"; W.NextPost(); return end
  if not d.checkedAt or GetTime() - d.checkedAt > PRICE_AGE then Recheck(d) return end
  if Throttled() then Status(v, BUSY, "error") return end
  local slot = PostSlot(b)
  if not slot then
    d.failed, d.why = true, "not posted: " .. LOCKED
    v.table:Refresh(); W.UpdatePostButton()
    return
  end
  local location = Location(slot)
  if A.IsSellItemValid and not A.IsSellItemValid(location, false) then
    d.done, d.doneText, d.failed, d.why = true, "can't sell", true, "the auction house won't take this item"
    W.NextPost()
    return
  end
  -- commodity or not: the bag slot says, or while the game hasn't loaded it yet ("unknown"), the search did
  local status = A.GetItemCommodityStatus and A.GetItemCommodityStatus(location)
  local commodity
  if status == COMMODITY then commodity = true
  elseif status == ITEM_STATUS then commodity = false
  elseif d.commodity ~= nil then commodity = d.commodity
  elseif not A.GetItemCommodityStatus then commodity = false
  else
    Status(v, "The game hasn't loaded this item yet: click Post again in a moment.", "error")
    return
  end
  -- how many the game lets you post from that slot's item (every stack of a commodity; like items for the rest)
  -- (only what isn't locked; without the game's count, every unlocked stack of a commodity, one of anything else)
  local free = b.free or b.count
  local available = A.GetAvailablePostCount and A.GetAvailablePostCount(location) or (commodity and free or 1)
  local qty = math.max(1, math.min(d.qty or free, available or 1, free))
  if C_Item and C_Item.DoesItemExist and not C_Item.DoesItemExist(location) then
    d.failed, d.why = true, "not posted: the game can't find it in that bag slot (check your bags again)"
    v.table:Refresh(); W.UpdatePostButton()
    return
  end
  -- the deposit has to be affordable, or the game refuses without saying why
  local deposit
  if commodity and A.CalculateCommodityDeposit then deposit = A.CalculateCommodityDeposit(d.itemID, GB.Pricing.Rules().duration, qty)
  elseif not commodity and A.CalculateItemDeposit then deposit = A.CalculateItemDeposit(location, GB.Pricing.Rules().duration, qty) end
  if deposit and deposit > (GetMoney() or 0) then
    d.failed, d.why = true, "not posted: the deposit is " .. UI.Money(deposit) .. " and you don't have it"
    v.table:Refresh(); W.UpdatePostButton()
    return
  end
  local duration = GB.Pricing.Rules().duration
  local unit, before = d.unit, GB.BagCount(d.itemID)
  -- the call, exactly as the game's own sell tab makes it, straight from the click
  local function act()
    if commodity then return A.PostCommodity(location, duration, qty, unit) end
    return A.PostItem(location, duration, qty, nil, unit)
  end
  local call = string.format("C_AuctionHouse.%s(bag %d slot %d = item %d, duration %s, quantity %d, %s%d)", commodity and "PostCommodity" or "PostItem",
    slot.bag, slot.slot, d.itemID, tostring(duration), qty, commodity and "unit price " or "bid nil, buyout ", unit)
  -- just before the call: state only, nothing redrawn
  local function arm(entry)
    v.posting = true
    d.posting, d.duration, d.failed = qty, duration, nil
    postWatch.row, postWatch.call, postWatch.qty, postWatch.commodity = d, entry, qty, commodity
    postWatch.before, postWatch.armedAt, postWatch.deadline = before, GetTime(), GetTime() + POST_WAIT
    postWatch.settleAt, postWatch.lastError, postWatch.confirm, postWatch.confirmed, postWatch.poll = nil, nil, false, nil, 0
    postWatch.multisell, postWatch.created, postWatch.seen, postWatch.popup, postWatch.popupWhich = nil, nil, nil, nil, nil
    for _, e in ipairs(POST_EVENTS) do pcall(postWatch.RegisterEvent, postWatch, e) end
    GB.Ledger.ExpectPost(location, duration, qty, unit, commodity)
  end
  local function after(needsConfirm, blocked)
    if postWatch.row ~= d then return end      -- settled during the call: the row already says how
    if blocked then PostFinished(false, "the game blocked " .. blocked) return end
    W.UpdatePostButton()
    -- true back from the game means it wants its own "are you sure" first: its sell tab is handed the post,
    -- so the game's popup appears and confirming there sends it (nothing is confirmed for you)
    if needsConfirm then
      local frame = AuctionHouseFrame and (commodity and AuctionHouseFrame.CommoditiesSellFrame or AuctionHouseFrame.ItemSellFrame)
      if frame and frame.CachePendingPost then
        if commodity then frame:CachePendingPost(location, duration, qty, unit) else frame:CachePendingPost(location, duration, qty, nil, unit) end
      end
      WaitForPopup(GetTime())
    end
  end
  return act, after, call, arm
end

-- the ledger writes the post down itself (it watches every post, whoever makes it)
function PostFinished(ok, why, posted)
  local v = views.post
  postWatch:UnregisterAllEvents()
  local d = postWatch.row
  postWatch.row, postWatch.popup, postWatch.multisell, postWatch.settleAt = nil, nil, nil, nil
  v.posting = false
  if postWatch.confirm then Status(v, "") end
  if d then
    if ok then
      posted = (posted and posted > 0) and posted or d.posting or d.have
      d.done, d.doneText, d.doneTone = true, "posted", "buy"
      GB.Ledger.PostProven(d.itemID, posted)
      d.why = posted < d.have and (posted .. " of " .. d.have .. " posted: check again for the rest") or (posted .. " posted at " .. UI.Money(d.unit) .. " each")
      GB.Query.Forget(d.itemID)
    else
      d.failed, d.why = true, "not posted: " .. (why or "the post failed")
    end
  end
  v.table:Refresh()
  if ok then W.NextPost() else PostSummary(); W.UpdatePostButton() end
end

-- the items leaving the bags: all of them settles it in a moment; some of them waits a little longer for
-- the rest. A multi-sell (several auctions from one click) is settled by its own progress instead.
local function NoteBags(now)
  if postWatch.multisell then return end
  local n = PostedSoFar()
  if n <= 0 or n == postWatch.seen then return end
  postWatch.seen = n
  postWatch.settleAt = now + (n >= (postWatch.qty or 1) and SETTLE or SETTLE_PART)
end

postWatch:SetScript("OnEvent", GB.Safe(function(_, event, a1, a2)
  local d = postWatch.row
  if not d then return end
  local now = GetTime()
  if event == "AUCTION_HOUSE_AUCTION_CREATED" then
    if postWatch.multisell then postWatch.deadline = now + MULTISELL_WAIT return end   -- its progress counts them
    postWatch.created = (postWatch.created or 0) + 1
    if postWatch.commodity or (postWatch.qty or 1) <= 1 or postWatch.created >= postWatch.qty then
      PostFinished(true, nil, math.max(PostedSoFar(), d.posting or 0))
    else
      postWatch.settleAt = now + SETTLE_PART     -- one auction of several: the rest may still follow
    end
  elseif event == "AUCTION_MULTISELL_START" then
    postWatch.multisell = { total = tonumber(a1) or postWatch.qty, done = 0 }
    postWatch.settleAt, postWatch.deadline = nil, now + MULTISELL_WAIT
  elseif event == "AUCTION_MULTISELL_UPDATE" then
    local m = postWatch.multisell or { total = tonumber(a2) or postWatch.qty, done = 0 }
    postWatch.multisell = m
    m.done, m.total = tonumber(a1) or m.done, tonumber(a2) or m.total
    postWatch.deadline = now + MULTISELL_WAIT
    if m.total and m.done >= m.total then PostFinished(true, nil, math.max(PostedSoFar(), m.done)) end
  elseif event == "AUCTION_MULTISELL_FAILURE" then
    local n = math.max(PostedSoFar(), postWatch.multisell and postWatch.multisell.done or 0)
    if n > 0 then PostFinished(true, nil, n) else PostFinished(false, postWatch.lastError or "the auction house stopped it") end
  elseif event == "AUCTION_HOUSE_POST_WARNING" then
    WaitForPopup(now)
  elseif event == "AUCTION_HOUSE_POST_ERROR" then
    PostFinished(false, postWatch.lastError or "the auction house refused it")
  elseif event == "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED" then
    if PostedSoFar() == 0 then PostFinished(false, "the auction house was busy and dropped it: click Post again") end
  elseif event == "AUCTION_HOUSE_SHOW_ERROR" then
    -- the game's own auction house error (a1 is its number); its text usually follows as a red message
    postWatch.lastError = postWatch.lastError or ("auction house error " .. tostring(a1))
    postWatch.deadline = math.min(postWatch.deadline, now + 1)
  elseif event == "UI_ERROR_MESSAGE" then
    local text = type(a2) == "string" and a2 or (type(a1) == "string" and a1) or nil
    if not text then return end
    postWatch.lastError = text     -- the game's own words, shown if the post doesn't go through
    -- an auction error ends it at once (a "not enough rage" from a keybind mustn't)
    if (text == ERR_NOT_ENOUGH_MONEY or text:lower():find("auction")) and PostedSoFar() == 0 then PostFinished(false, text) end
  else
    NoteBags(now)
  end
end, "posting"))
postWatch:SetScript("OnUpdate", GB.Safe(function(_, elapsed)
  local d = postWatch.row
  if not d then return end
  -- the call never came back (a Lua error inside it): there is nothing to wait for
  if postWatch.call and not postWatch.call.back then PostFinished(false, "the post call failed with an error (see /gb diag)") return end
  local now = GetTime()
  if postWatch.confirm and not postWatch.confirmed then
    local at = GB.Ledger.confirmedAt
    if at and at >= postWatch.armedAt then
      postWatch.confirmed, postWatch.deadline = true, now + POST_WAIT    -- confirmed: proof awaited as for any post
    elseif postWatch.popup and not PopupUp() then
      PostFinished(false, "not confirmed in the game's popup")
      return
    end
  end
  postWatch.poll = (postWatch.poll or 0) + (elapsed or 0)
  if postWatch.poll > 0.25 then
    postWatch.poll = 0
    NoteBags(now)
  end
  if postWatch.settleAt and now >= postWatch.settleAt and not postWatch.multisell then
    PostFinished(true, nil, PostedSoFar())
  elseif now > postWatch.deadline then
    local n = math.max(PostedSoFar(), postWatch.multisell and postWatch.multisell.done or 0)
    if n > 0 then PostFinished(true, nil, n)
    elseif postWatch.confirm and not postWatch.confirmed then PostFinished(false, "not confirmed in the game's popup")
    -- never a bare "no answer": the game's own words if it gave any, else exactly what was sent and what came back
    else PostFinished(false, postWatch.lastError or ("still in your bags; " .. GB.CallFacts(postWatch.call))) end
  end
end, "posting"))

---------------------------------------------------------------------------
-- Cancel: your auctions that someone undercut, one cancel per click
---------------------------------------------------------------------------

local function BuildCancel(p)
  local v = CreateFrame("Frame", nil, p)
  v:SetAllPoints()
  v.scan = UI.Button(v, "Check my auctions", 150, 26)
  v.scan:SetPoint("TOPLEFT", PAD, -12)
  v.summary = UI.Text(v, 13, "ink")
  v.summary:SetPoint("LEFT", v.scan, "RIGHT", 12, 0)
  v.status = UI.Text(v, 12, "muted", "RIGHT")
  v.status:SetPoint("TOPRIGHT", -PAD, -19)
  v.status:SetWidth(250)
  v.info = UI.Note(v, WIDTH - 2 * PAD)
  v.info:SetPoint("TOPLEFT", PAD, -48)
  v.info:SetText("Your auctions where someone is now cheaper. Ones with a bid, or undercut by a price far under the usual one (a dump), are kept. Cancelling gives up the deposit.")
  v.table = UI.Table(v, {
    { key = "name", label = "Item", width = 0, render = function(d) return UI.ItemText(d.itemID, d.name) end },
    { key = "count", label = "Quantity", width = 62, align = "RIGHT" },
    { key = "unit", label = "Yours each", width = 96, align = "RIGHT", render = function(d) return UI.Money(d.unit) end },
    { key = "lowest", label = "Cheapest other", width = 108, align = "RIGHT", render = function(d) return d.lowest and UI.Money(d.lowest) or UI.Color("faint", "-") end },
    { key = "action", label = "What to do", width = 160, sortValue = function(d) return d.cancel and 0 or 1 end, render = function(d)
        if d.done then return UI.Color("muted", d.doneText or "cancelled") end
        if d.cancel then return UI.Verdict("sell", "Cancel: undercut") end
        return UI.Color(d.failed and "sell" or "muted", d.why or "checking...") end },
  }, { sortKey = "order", sortDir = 1, onEnter = function(row, d) UI.ItemTooltip(row, d.itemID) end })
  v.table:SetPoint("TOPLEFT", PAD - 2, -88); v.table:SetPoint("BOTTOMRIGHT", -(PAD - 2), 54)
  v.cancel = UI.Button(v, "Cancel", 270, 30, "primary")
  v.cancel:SetPoint("BOTTOMRIGHT", -(PAD - 2), 12)
  v.cancel:Disable()
  v.scan:SetScript("OnClick", function()
    local ok, err = pcall(W.ScanCancel)
    if not ok then
      Status(v, "The check failed: " .. Short(err), "error")
      GB.Report(err, "Check my auctions")
    end
  end)
  v.cancel:SetAction(function() return W.PrepareCancel() end, "cancelling")
  v.table:SetData({}, "Click \"Check my auctions\" to find the ones somebody undercut.")
  return v
end

local function CancelSummary()
  local v = views.cancel
  local n = 0
  for _, d in ipairs(v.table.data) do if d.cancel and not d.done then n = n + 1 end end
  v.summary:SetText(#v.table.data == 0 and "" or (n > 0 and UI.Color("sell", n .. " undercut") or UI.Color("buy", "none undercut")))
end

-- Like the Sell check: each item is judged on its own, and a failure says so in the status line.
-- Gear is judged against the same variant (item level, suffix) only.
local function ReadOwned()
  local v = views.cancel
  local rows, items = {}, {}
  local pending, failed, firstError = 0, 0, nil
  local function Fail(err)
    failed, firstError = failed + 1, firstError or Short(err)
    GB.Report(err, "Check my auctions")
  end
  local function ShowStatus(first)
    local text = pending > 0 and ("checking " .. pending .. (first and " items..." or " more...")) or (first and "" or "checked " .. UI.Ago(time()))
    if failed > 0 then text = (text ~= "" and (text .. ". ") or "") .. failed .. " failed: " .. firstError end
    Status(v, text, failed > 0 and "error" or nil)
  end
  local A = C_AuctionHouse
  for i = 1, A.GetNumOwnedAuctions() or 0 do
    local info = A.GetOwnedAuctionInfo(i)
    local itemID = info and info.itemKey and info.itemKey.itemID
    -- still up (status 0), with a buyout (its price each)
    if itemID and info.status == 0 and info.buyoutAmount and info.buyoutAmount > 0 then
      local name = (info.itemLink and info.itemLink:match("%[(.-)%]")) or ItemName(itemID) or ("item " .. itemID)
      local match = GB.Query.IsEquipment(itemID) and info.itemKey or nil
      local key = GB.Query.CacheKey(itemID, match)
      local row = { itemID = itemID, name = name, count = info.quantity or 1, unit = info.buyoutAmount, auctionID = info.auctionID,
                    bid = info.bidder ~= nil and 1 or 0, order = #rows + 1, key = key }
      rows[#rows + 1] = row
      items[key] = items[key] or { itemID = itemID, name = name, match = match }
    end
  end
  v.table.selected = nil
  v.table:SetData(rows, "You have no auctions with a buyout up.")
  for key, it in pairs(items) do
    local itemID = it.itemID
    local function Judge(r)
      local prices = GB.Pricing.Prices(itemID)
      for _, row in ipairs(rows) do
        if row.key == key then
          row.lowest = r.lowest
          if r.failed then row.why, row.failed = "no answer: check again", true
          elseif row.bid > 0 then row.why = "has a bid: keep"
          elseif not r.lowest or r.lowest >= row.unit then row.why = "still the cheapest"
          elseif prices and r.lowest < prices.floor then row.why = "undercut by a dump: keep"
          else row.cancel = true end
        end
      end
    end
    local function Done(r)
      pending = pending - 1
      if v.table.data ~= rows then return end   -- a newer check replaced this one
      local ok, err = pcall(Judge, r)
      if not ok then Fail(err) end
      v.table:Refresh()
      ShowStatus()
      W.UpdateCancelButton()
    end
    pending = pending + 1
    local cached = GB.Query.cache[key]
    if cached and time() - cached.time < 120 then Done(cached)
    elseif not GB.Query.Search(itemID, it.name, Done, it.match) then pending = pending - 1 end
  end
  ShowStatus(true)
  W.UpdateCancelButton()
end

-- Your auctions are asked for once the auction house throttle is ready (a request sent while it is busy
-- is dropped without a word), then read when the game says the list is in, or after a few seconds.
local ownedWait = CreateFrame("Frame")
local OWNED_SEND_WAIT, OWNED_READ_WAIT = 10, 3
local function OwnedListReady()
  ownedWait:UnregisterAllEvents()
  ownedWait.sendBy, ownedWait.readBy = nil, nil
  local ok, err = pcall(ReadOwned)
  if not ok then
    Status(views.cancel, "The check failed: " .. Short(err), "error")
    GB.Report(err, "Check my auctions")
  end
end
ownedWait:SetScript("OnEvent", OwnedListReady)
ownedWait:SetScript("OnUpdate", GB.Safe(function()
  local now = GetTime()
  if ownedWait.sendBy then
    if not Throttled() then
      ownedWait.sendBy, ownedWait.readBy = nil, now + OWNED_READ_WAIT
      ownedWait:RegisterEvent("OWNED_AUCTIONS_UPDATED")
      C_AuctionHouse.QueryOwnedAuctions({ { sortOrder = 1, reverseSort = false } })
    elseif now > ownedWait.sendBy then
      OwnedListReady()        -- never ready: what the game already holds is read
    end
  elseif ownedWait.readBy and now > ownedWait.readBy then
    OwnedListReady()          -- the list may have been there already: no update comes for it
  end
end, "Check my auctions"))

function W.ScanCancel()
  local v = views.cancel
  if not NeedAuctionHouse(v) then return end
  local A = C_AuctionHouse
  if not (A.GetNumOwnedAuctions and A.GetOwnedAuctionInfo) then Status(v, GB.Query.NO_API, "error") return end
  Status(v, "reading your auctions...")
  if not A.QueryOwnedAuctions then OwnedListReady() return end
  ownedWait:UnregisterAllEvents()
  ownedWait.sendBy, ownedWait.readBy = GetTime() + OWNED_SEND_WAIT, nil
end

function W.UpdateCancelButton()
  local v = views.cancel
  v.next = nil
  for _, d in ipairs(v.table.data) do if d.cancel and not d.done then v.next = d break end end
  v.table:Select(v.next)
  CancelSummary()
  if v.cancelling then
    v.cancel:SetLabel("Cancelling...")
    v.cancel:Disable()
  elseif v.next then
    v.cancel:SetLabel(string.format("Cancel %d %s", v.next.count, v.next.name))
    v.cancel:Enable()
  else
    v.cancel:SetLabel("Nothing to cancel")
    v.cancel:Disable()
  end
end

-- One cancel at a time: the row is only marked cancelled when the game says that auction was cancelled.
local cancelWatch = CreateFrame("Frame")
local CANCEL_WAIT = 5
local function CancelSettled(ok, why)
  cancelWatch:UnregisterAllEvents()
  local d = cancelWatch.row
  cancelWatch.row, cancelWatch.deadline, cancelWatch.call, cancelWatch.failAt = nil, nil, nil, nil
  local v = views.cancel
  if d then
    if ok then d.done, d.failed = true, nil
    else
      d.done, d.failed, d.why = false, true, "not cancelled: " .. (why or "the auction house didn't answer")
      d.cancel = true
      Status(v, "Not cancelled: " .. (why or "no answer"), "error")
    end
  end
  v.cancelling = false
  v.table:Refresh()
  W.UpdateCancelButton()
end
cancelWatch:SetScript("OnEvent", GB.Safe(function(_, event, a1, a2)
  if not cancelWatch.row then return end
  if event == "AUCTION_CANCELED" then
    if a1 == nil or a1 == cancelWatch.id then CancelSettled(true) end
  elseif event == "AUCTION_HOUSE_SHOW_ERROR" then
    cancelWatch.lastError = cancelWatch.lastError or ("auction house error " .. tostring(a1))
    cancelWatch.failAt = cancelWatch.failAt or (GetTime() + 0.5)
  elseif event == "UI_ERROR_MESSAGE" then
    local text = type(a2) == "string" and a2 or (type(a1) == "string" and a1) or nil
    if text and text:lower():find("auction") then cancelWatch.lastError, cancelWatch.failAt = text, GetTime() end
  end
end, "cancelling"))
cancelWatch:SetScript("OnUpdate", GB.Safe(function()
  if not cancelWatch.row then return end
  if cancelWatch.call and not cancelWatch.call.back then CancelSettled(false, "the cancel call failed with an error") return end
  local now = GetTime()
  if cancelWatch.failAt and now >= cancelWatch.failAt then CancelSettled(false, cancelWatch.lastError)
  elseif cancelWatch.deadline and now >= cancelWatch.deadline then
    -- no word from the game: if the auction can't be cancelled any more it is gone (cancelled or sold)
    local A = C_AuctionHouse
    if A.CanCancelAuction and not A.CanCancelAuction(cancelWatch.id) then
      cancelWatch.row.doneText = "gone (no answer)"
      CancelSettled(true)
    else CancelSettled(false, nil) end
  end
end, "cancelling"))

-- What the Cancel click should do: the one game call to make, what follows it, its description, and what
-- is set up just before it.
function W.PrepareCancel()
  local v = views.cancel
  local d = v.next
  if not d or v.cancelling then return end
  if not NeedAuctionHouse(v) then return end
  local A = C_AuctionHouse
  if Throttled() then Status(v, BUSY, "error") return end
  if A.CanCancelAuction and not A.CanCancelAuction(d.auctionID) then
    d.done, d.cancel, d.doneText = true, false, "sold or gone already"
  elseif A.GetCancelCost and (A.GetCancelCost(d.auctionID) or 0) > 0 then
    d.done, d.cancel, d.doneText = true, false, "has a bid: kept"   -- cancelling it would cost gold
  else
    local id = d.auctionID
    return function() A.CancelAuction(id) end, function(_, blocked)
      if blocked then
        if cancelWatch.row == d then CancelSettled(false, "the game blocked " .. blocked) end
        return
      end
      if cancelWatch.row ~= d then return end      -- already answered during the call
      v.table:Refresh()
      W.UpdateCancelButton()
    end, string.format("C_AuctionHouse.CancelAuction(auction %s)", tostring(id)),
    function(entry)
      v.cancelling = true
      d.failed = nil
      cancelWatch.row, cancelWatch.id, cancelWatch.call = d, id, entry
      GB.Ledger.ExpectCancel(id)
      cancelWatch.deadline, cancelWatch.failAt, cancelWatch.lastError = GetTime() + CANCEL_WAIT, nil, nil
      for _, e in ipairs({ "AUCTION_CANCELED", "AUCTION_HOUSE_SHOW_ERROR", "UI_ERROR_MESSAGE" }) do pcall(cancelWatch.RegisterEvent, cancelWatch, e) end
    end
  end
  v.table:Refresh()
  W.UpdateCancelButton()
end

-- The game says which function it refused: the row waiting on it gets that as its reason.
GB.OnBlocked(function(func)
  local why = "the game blocked " .. func
  if postWatch.row then
    postWatch.lastError = why
    postWatch.deadline = GetTime()          -- settle it now (the bags are looked at one last time)
  end
  if views.cancel and views.cancel.cancelling and cancelWatch.row then
    CancelSettled(false, why)
  end
  local shop = views.shop
  if shop and (shop.buying or shop.quote) then
    LeaveBuy(shop)
    -- the Buy button works again for the row still picked
    if shop.item and shop.selected then W.SelectListing(shop.selected) end
    shop.note:SetText(UI.Color("sell", "Not bought: " .. why))
    Status(shop, "blocked", "error")
  end
end)

---------------------------------------------------------------------------
-- The window
---------------------------------------------------------------------------

local TABS = { { key = "shop", label = "Shop" }, { key = "post", label = "Sell" }, { key = "cancel", label = "Cancel" } }

local function Build()
  win = UI.Window("GoldBoardAHWindow", WIDTH, HEIGHT, "Gold Board", "ahPos", {
    parent = UIParent, escape = false,
    onClose = function() GB.db.settings.ahWindow = false end,
    onRightClick = function() GB.db.settings.ahPos = nil; W.Place() end,   -- dock it beside the auction house again
    hint = "Drag to move. Right-click to put it back beside the auction house.",
  })
  local body = CreateFrame("Frame", nil, win)
  body:SetPoint("TOPLEFT", 0, -UI.TOP); body:SetPoint("BOTTOMRIGHT")
  views.shop, views.post, views.cancel = BuildShop(body), BuildPost(body), BuildCancel(body)
  UI.Rule(win, -(UI.TOP - 1))
  tabs = UI.Tabs(win, TABS, function(key)
    for k, view in pairs(views) do view:SetShown(k == key) end
    GB.db.settings.ahTab = key
    if key == "shop" and not views.shop.item then W.ShowDeals() end
  end)
  tabs:SetPoint("TOPLEFT", PAD - 6, -UI.HEAD)
  tabs:SetPoint("TOPRIGHT", -PAD, -UI.HEAD)
end

-- Where you dragged it, or docked beside the auction house. It is anchored to the game's auction house
-- window but never made a child of it, and nothing is written into that window: Gold Board's own frames
-- stay out of the game's protected ones.
function W.Place()
  local ah = GB.Query.Frame()
  win:SetFrameStrata("HIGH")
  if UI.RestorePosition(win, "ahPos") then return end
  win:ClearAllPoints()
  if ah then win:SetPoint("TOPLEFT", ah, "TOPRIGHT", 6, 0) else win:SetPoint("CENTER") end
end
local Place = W.Place

function W.Toggle()
  if not win then Build() end
  if win:IsShown() then win:Hide(); GB.db.settings.ahWindow = false
  else Place(); win:Show(); GB.db.settings.ahWindow = true; W.OnShow() end
end

function W.OnShow()
  win.sub:SetText(GB.Signals.Describe())
  local key = GB.db.settings.ahTab
  tabs:Select(tabs:Has(key) and key or "shop")
end

-- the button on the auction house that brings the window back, and the window docked beside it
local function Dock()
  local ah = GB.Query.Frame()
  if not ah then return false end
  if not W.toggle then
    W.toggle = UI.Button(UIParent, "Gold Board", 96, 22)        -- our own frame, only anchored to the game's
    W.toggle:SetPoint("BOTTOMRIGHT", ah, "TOPRIGHT", -2, 2)   -- above its top right corner, clear of its own buttons
    W.toggle:SetFrameStrata("HIGH")
    W.toggle:SetScript("OnClick", W.Toggle)
  end
  W.toggle:Show()
  if win and win:IsShown() then Place() end
  return true
end

local atAuctionHouse = false
local function OnOpen()
  if atAuctionHouse then return end      -- the game announces it twice (two events): once is enough
  atAuctionHouse = true
  GB.Ledger.RefreshHoldings()
  if not win then Build() end
  -- the game may build its auction house window a moment after saying it opened
  if not Dock() then C_Timer.After(0, function() if not Dock() then C_Timer.After(0.5, Dock) end end) end
  -- last visit's listings are stale: the Shop starts from the deals again
  LeaveBuy(views.shop)
  views.shop.item = nil
  if GB.db.settings.ahWindow ~= false then Place(); win:Show(); W.OnShow() end
end
local function OnClose()
  atAuctionHouse = false
  if W.toggle then W.toggle:Hide() end
  if win then
    LeaveBuy(views.shop)
    local wasRechecking = views.post.rechecking
    views.post.rechecking, views.post.recheckOf = false, nil    -- a re-check still on its way is dropped
    if wasRechecking then W.UpdatePostButton() end               -- and the button stops saying "Checking the price..."
    ownedWait:UnregisterAllEvents(); ownedWait.sendBy, ownedWait.readBy = nil, nil   -- no list read after closing
    win:Hide()
  end
end

local ev = CreateFrame("Frame")
for _, e in ipairs({ "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED", "PLAYER_INTERACTION_MANAGER_FRAME_SHOW", "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" }) do
  pcall(ev.RegisterEvent, ev, e)
end
ev:SetScript("OnEvent", GB.Safe(function(_, event, kind)
  local auctioneer = (Enum and Enum.PlayerInteractionType and Enum.PlayerInteractionType.Auctioneer)
  if event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" then
    if auctioneer ~= nil and kind == auctioneer then OnOpen() end
  elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" then
    if auctioneer ~= nil and kind == auctioneer then OnClose() end
  elseif event == "AUCTION_HOUSE_SHOW" then OnOpen()
  else OnClose() end
end, "auction house window"))
