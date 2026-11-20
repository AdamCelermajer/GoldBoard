-- The Gold Board window beside the auction house: Shop, Post and Cancel.
-- Every buy, post and cancel is one click of yours (the game requires it); the window does the
-- searching, pricing and finding.

local _, GB = ...
local UI = GB.UI
local W = {}
GB.AHWindow = W

local WIDTH, HEIGHT = 600, 460
local win, tabs, views = nil, nil, {}

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function ItemName(id)
  local n = C_Item.GetItemNameByID(id)
  if not n and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(id) end
  return n
end

-- bags: itemID -> { count, slots = { {bag, slot, count} } } for items you could sell
local function BagItems()
  local out = {}
  for bag = 0, (NUM_BAG_SLOTS or 4) do
    for slot = 1, C_Container.GetContainerNumSlots(bag) do
      local info = C_Container.GetContainerItemInfo(bag, slot)
      if info and info.itemID and not info.isBound then
        local e = out[info.itemID] or { count = 0, slots = {} }
        e.count = e.count + (info.stackCount or 1)
        e.slots[#e.slots + 1] = { bag = bag, slot = slot, count = info.stackCount or 1 }
        out[info.itemID] = e
      end
    end
  end
  return out
end

local function AuctionatorPrice(id)
  local api = Auctionator and Auctionator.API and Auctionator.API.v1
  if not (api and api.GetAuctionPriceByItemID) then return nil end
  local ok, p = pcall(api.GetAuctionPriceByItemID, "Gold Board", id)
  if not ok then return nil end
  local okAge, age = pcall(api.GetAuctionAgeByItemID, "Gold Board", id)
  return p, okAge and age or nil
end

local function Status(view, text) view.status:SetText(text or "") end

---------------------------------------------------------------------------
-- Shop: deals at your auction house, any item's listings, buy the one you pick
---------------------------------------------------------------------------

local function BuildShop(p)
  local v = CreateFrame("Frame", nil, p)
  v:SetAllPoints()
  v.search = UI.Input(v, 230, "Search an item")
  v.search:SetPoint("TOPLEFT", 12, -10)
  v.go = UI.Button(v, "Search", 80, 24)
  v.go:SetPoint("LEFT", v.search, "RIGHT", 6, 0)
  v.dealsBtn = UI.Button(v, "Deals", 80, 24, "quiet")
  v.dealsBtn:SetPoint("LEFT", v.go, "RIGHT", 6, 0)
  v.status = UI.Text(v, 12, "muted", "RIGHT")
  v.status:SetPoint("TOPRIGHT", -14, -16)
  v.status:SetWidth(170)

  v.title = UI.Text(v, 15, "ink", "LEFT", UI.FONT_TITLE)
  v.title:SetPoint("TOPLEFT", 14, -46)
  v.sub = UI.Text(v, 12, "muted")
  v.sub:SetPoint("TOPLEFT", 14, -64)
  v.sub:SetWidth(WIDTH - 28)

  -- deals: under your buy-below price at the last known price
  v.deals = UI.Table(v, {
    { key = "name", label = "Item", width = 0, render = function(d) return UI.ItemText(d.itemID, d.name) end },
    { key = "cheapest", label = "Cheapest", width = 96, align = "RIGHT", render = function(d) return UI.Money(d.cheapest) end },
    { key = "buyBelow", label = "Buy below", width = 96, align = "RIGHT", render = function(d) return UI.Money(d.buyBelow) end },
    { key = "profit", label = "Profit each", width = 96, align = "RIGHT", render = function(d) return UI.Color("buy", UI.Money(d.profit, { sign = true })) end },
    { key = "sold", label = "Sold/day", width = 64, align = "RIGHT", render = function(d) return d.sold and string.format("%.0f", d.sold) or "-" end },
  }, { sortKey = "score", sortDir = -1,
       onClick = function(_, d) W.OpenItem(d.itemID) end,
       onEnter = function(row, d) UI.ItemTooltip(row, d.itemID) end })
  v.deals:SetPoint("TOPLEFT", 10, -86); v.deals:SetPoint("BOTTOMRIGHT", -10, 48)

  -- one item's listings, grouped by price and stack size
  v.list = UI.Table(v, {
    { key = "unit", label = "Price each", width = 120, align = "RIGHT", render = function(d)
        local t = UI.Money(d.unit)
        if v.item and v.item.buyBelow and d.unit <= v.item.buyBelow then t = UI.Color("buy", t) end
        return t end },
    { key = "count", label = "Stack", width = 60, align = "RIGHT" },
    { key = "n", label = "Auctions", width = 70, align = "RIGHT" },
    { key = "stackPrice", label = "Stack price", width = 120, align = "RIGHT", render = function(d) return UI.Money(d.buyout) end },
    { key = "vs", label = "vs sells for", width = 0, align = "RIGHT", render = function(d)
        if not d.vs then return "-" end
        local s = UI.Pct(d.vs - 1)
        return d.vs <= 0.85 and UI.Color("buy", s) or d.vs > 1 and UI.Color("sell", s) or s end },
    { key = "mine", label = "", width = 40, sort = false, render = function(d) return d.mine and UI.Color("brass", "you") or "" end },
  }, { sortKey = "unit", sortDir = 1, onClick = function(_, d) W.SelectListing(d) end })
  v.list:SetPoint("TOPLEFT", 10, -86); v.list:SetPoint("BOTTOMRIGHT", -10, 48)
  v.list:Hide()

  v.buy = UI.Button(v, "Buy", 230, 28, "primary")
  v.buy:SetPoint("BOTTOMRIGHT", -10, 12)
  v.buy:Disable()
  v.buy:SetScript("OnClick", function() W.BuySelected() end)
  v.back = UI.Button(v, "Back to deals", 120, 28, "quiet")
  v.back:SetPoint("BOTTOMLEFT", 10, 12)
  v.back:SetScript("OnClick", function() W.ShowDeals() end)
  v.note = UI.Text(v, 12, "muted")
  v.note:SetPoint("LEFT", v.back, "RIGHT", 10, 0)
  v.note:SetWidth(200)

  local function DoSearch()
    local text = v.search:GetText()
    v.search:ClearFocus()
    if text == "" then return end
    local id = C_Item.GetItemInfoInstant and C_Item.GetItemInfoInstant(text) or GB.IDFromName(text)
    W.OpenItem(id, text)
  end
  v.search:SetScript("OnEnterPressed", DoSearch)
  v.go:SetScript("OnClick", DoSearch)
  v.dealsBtn:SetScript("OnClick", function() W.ShowDeals() end)
  return v
end

function W.ShowDeals()
  local v = views.shop
  v.item, v.selected = nil, nil
  v.list:Hide(); v.deals:Show(); v.back:Hide(); v.note:SetText("")
  v.buy:SetLabel("Buy"); v.buy:Disable()
  local list = {}
  for id, s in pairs(GB.Signals.All()) do
    local ac = AuctionatorPrice(id)
    local cheapest = (ac and ac > 0) and ac or s.minBuy
    if cheapest and cheapest > 0 and s.buyBelow and cheapest <= s.buyBelow and (s.soldPerDay or 0) >= 1 then
      local profit = s.sell * 0.95 - cheapest
      list[#list + 1] = { itemID = id, name = ItemName(id) or ("item " .. id), cheapest = cheapest, buyBelow = s.buyBelow,
        profit = profit, sold = s.soldPerDay, score = profit * math.min(s.soldPerDay, 50) }
    end
  end
  v.title:SetText("Deals on " .. (GB.Signals.Meta().label or GB.AH()))
  v.sub:SetText("Cheapest from Auctionator's last scan (or the Gold Board's last TSM update) under your buy-below price. Click one to see its live listings.")
  v.deals:SetData(list, "No deals right now. Open the auction house long enough for Auctionator's scan, or start the Gold Board on your PC and /reload.")
  Status(v, #list .. " deals")
  -- names the game hadn't loaded yet arrive a moment later
  C_Timer.After(1.5, function()
    local changed = false
    for _, d in ipairs(list) do
      if d.name:find("^item ") then
        local n = C_Item.GetItemNameByID(d.itemID)
        if n then d.name, changed = n, true end
      end
    end
    if changed and v.deals:IsShown() then v.deals:Refresh() end
  end)
end

function W.OpenItem(itemID, name)
  local v = views.shop
  name = name or (itemID and ItemName(itemID))
  if not name then Status(v, "Item not found: type its exact name.") return end
  v.deals:Hide(); v.list:Show(); v.back:Show()
  local s = itemID and GB.Signals.Get(itemID)
  v.item = { itemID = itemID, name = name, sell = s and s.sell, buyBelow = s and s.buyBelow }
  v.selected = nil
  v.buy:SetLabel("Buy"); v.buy:Disable()
  v.title:SetText(itemID and UI.ItemText(itemID, name) or name)
  v.sub:SetText(s and ("Sells for " .. UI.Money(s.sell) .. ", buy below " .. UI.Money(s.buyBelow)
    .. (s.soldPerDay and string.format(", about %.0f sold a day in EU", s.soldPerDay) or "")) or "No Gold Board price for this item yet.")
  v.list:SetData({}, "Searching...")
  Status(v, "Searching...")
  GB.Query.Search(itemID, name, function(r) W.ShowListings(r) end)
end

function W.ShowListings(r)
  local v = views.shop
  if not v.item or v.item.name ~= r.name then return end
  v.result = r
  local groups, byKey = {}, {}
  for _, a in ipairs(r.auctions) do
    local key = a.buyout .. "x" .. a.count .. (a.mine and "m" or "")
    local g = byKey[key]
    if not g then
      g = { unit = a.unit, count = a.count, buyout = a.buyout, n = 0, auctions = {}, mine = a.mine,
            vs = v.item.sell and a.unit / v.item.sell or nil }
      byKey[key] = g
      groups[#groups + 1] = g
    end
    g.n = g.n + 1
    g.auctions[#g.auctions + 1] = a
  end
  v.list:SetData(groups, "Nobody is selling it right now.")
  Status(v, #r.auctions .. " listings")
end

-- pick a listing: make sure one of its auctions is on the page the auction house holds, then Buy is live
function W.SelectListing(g)
  local v = views.shop
  v.selected = g
  v.list:Select(g)
  if g.mine then v.buy:SetLabel("That's your own auction"); v.buy:Disable() return end
  local a = g.auctions[1]
  if not a then v.buy:Disable() return end
  local key = v.item.name .. "|" .. a.page
  local function Ready()
    v.buy:SetLabel(string.format("Buy %d for %s", g.count, UI.Money(g.buyout)))
    v.buy:Enable()
    v.note:SetText(g.n > 1 and (g.n .. " like this") or "")
  end
  if GB.Query.listPage == key then Ready() return end
  v.buy:SetLabel("Finding it...")
  v.buy:Disable()
  GB.Query.LoadPage(v.item.itemID, v.item.name, a.page, function() if v.selected == g then Ready() end end)
end

function W.BuySelected()
  local v = views.shop
  local g = v.selected
  if not g or not v.item then return end
  -- find the auction on the current page right now (indexes move when anything sells)
  local n = GetNumAuctionItems("list")
  for i = 1, n do
    local _, _, count, _, _, _, _, _, _, buyout, _, _, _, owner, _, _, itemID = GetAuctionItemInfo("list", i)
    if count == g.count and buyout == g.buyout and (not v.item.itemID or itemID == v.item.itemID) and not GB.Query.IsMine(owner) then
      PlaceAuctionBid("list", i, buyout)
      table.remove(g.auctions, 1)
      g.n = g.n - 1
      if g.n <= 0 then
        for gi, x in ipairs(v.list.data) do if x == g then table.remove(v.list.data, gi) break end end
        v.selected = nil
        v.buy:SetLabel("Buy"); v.buy:Disable()
        v.list:Refresh()
      else
        v.list:Refresh()
        v.note:SetText(g.n .. " left like this")
      end
      return
    end
  end
  -- not on this page any more: look for the next one
  table.remove(g.auctions, 1)
  g.n = g.n - 1
  if g.n > 0 then W.SelectListing(g) else v.buy:SetLabel("Gone: search again"); v.buy:Disable() end
end

---------------------------------------------------------------------------
-- Post: scan your groups, then post one item per click
---------------------------------------------------------------------------

local function BuildPost(p)
  local v = CreateFrame("Frame", nil, p)
  v:SetAllPoints()
  v.scan = UI.Button(v, "Scan my groups", 140, 24)
  v.scan:SetPoint("TOPLEFT", 12, -10)
  v.status = UI.Text(v, 12, "muted", "RIGHT")
  v.status:SetPoint("TOPRIGHT", -14, -16)
  v.status:SetWidth(300)
  v.info = UI.Text(v, 12, "muted")
  v.info:SetPoint("TOPLEFT", 14, -44)
  v.info:SetWidth(WIDTH - 28)
  v.info:SetText("Items from your groups that are in your bags, priced by each group's rules. Make groups in /gb.")
  v.table = UI.Table(v, {
    { key = "name", label = "Item", width = 0, render = function(d) return UI.ItemText(d.itemID, d.name) end },
    { key = "qty", label = "Post", width = 70, align = "RIGHT", render = function(d) return d.stacks and (d.stacks .. " x " .. d.stackSize) or "-" end },
    { key = "unit", label = "Price each", width = 100, align = "RIGHT", render = function(d) return d.unit and UI.Money(d.unit) or "-" end },
    { key = "state", label = "", width = 190, render = function(d)
        if d.done then return UI.Color("buy", "posted") end
        if d.unit then return UI.Color("ink", d.reason) end
        return UI.Color("muted", d.reason or "") end },
  }, { sortKey = "order", sortDir = 1, onClick = function(_, d) if d.unit and not d.done then views.post.current = d; views.post.table:Select(d); W.UpdatePostButton() end end,
       onEnter = function(row, d) UI.ItemTooltip(row, d.itemID) end })
  v.table:SetPoint("TOPLEFT", 10, -64); v.table:SetPoint("BOTTOMRIGHT", -10, 48)
  v.post = UI.Button(v, "Post", 260, 28, "primary")
  v.post:SetPoint("BOTTOMRIGHT", -10, 12)
  v.post:Disable()
  v.skip = UI.Button(v, "Skip", 80, 28, "quiet")
  v.skip:SetPoint("RIGHT", v.post, "LEFT", -6, 0)
  v.scan:SetScript("OnClick", function() W.ScanPost() end)
  v.post:SetScript("OnClick", function() W.PostCurrent() end)
  v.skip:SetScript("OnClick", function() if v.current then v.current.done, v.current.reason = true, "skipped" end; W.NextPost() end)
  return v
end

function W.ScanPost()
  local v = views.post
  local bags = BagItems()
  local rows, pending = {}, 0
  for name, g in pairs(GB.Groups.All()) do
    for itemID in pairs(g.items) do
      local b = bags[itemID]
      if b and b.count > (g.rules.keep or 0) then
        local row = { itemID = itemID, name = ItemName(itemID) or ("item " .. itemID), group = name, rules = g.rules,
                      have = b.count, reason = "searching...", order = #rows + 1 }
        rows[#rows + 1] = row
        pending = pending + 1
        GB.Query.Search(itemID, row.name, function(r)
          pending = pending - 1
          local prices = GB.Groups.Prices(itemID, g.rules)
          local mineLowest = r.lowestMine and (not r.lowest or r.lowestMine <= r.lowest)
          local unit, why = GB.Groups.PostPrice(prices, g.rules, r.lowest, mineLowest)
          row.reason = why
          if unit then
            unit = math.max(1, math.floor(unit))
            local maxStack = select(8, GetItemInfo(itemID)) or 1
            local size = math.max(1, math.min(g.rules.stack or 20, maxStack))
            local sellable = row.have - (g.rules.keep or 0)
            local stacks = math.min(g.rules.stacks or 5, math.floor(sellable / size))
            if stacks < 1 then size, stacks = sellable, 1 end
            row.unit, row.stackSize, row.stacks = unit, size, stacks
          end
          v.table:Refresh()
          Status(v, pending > 0 and ("searching " .. pending .. " more...") or "scan done")
          if pending == 0 then W.NextPost() end
        end)
      end
    end
  end
  v.table:SetData(rows, next(GB.Groups.All()) and "None of your group items are in your bags." or "No groups yet: open /gb, Groups, and make one.")
  Status(v, pending > 0 and ("searching " .. pending .. " items...") or "")
  v.current = nil
  W.UpdatePostButton()
end

function W.NextPost()
  local v = views.post
  v.current = nil
  for _, d in ipairs(v.table.data) do
    if d.unit and not d.done then v.current = d break end
  end
  v.table:Select(v.current)
  W.UpdatePostButton()
end

function W.UpdatePostButton()
  local v = views.post
  local d = v.current
  if v.posting then v.post:SetLabel("Posting...") v.post:Disable() return end
  if not d then v.post:SetLabel("Post"); v.post:Disable(); v.skip:Disable() return end
  v.post:SetLabel(string.format("Post %d x %d at %s", d.stacks, d.stackSize, UI.Money(d.unit)))
  v.post:Enable()
  v.skip:Enable()
end

local postWatch = CreateFrame("Frame")
function W.PostCurrent()
  local v = views.post
  local d = v.current
  if not d or v.posting then return end
  -- find a stack of it in the bags
  local b = BagItems()[d.itemID]
  if not b then d.done, d.reason = true, "not in your bags any more"; W.NextPost(); return end
  local slot = b.slots[1]
  for _, s in ipairs(b.slots) do if s.count >= d.stackSize then slot = s break end end
  ClearCursor()
  ClickAuctionSellItemButton()
  ClearCursor()
  C_Container.PickupContainerItem(slot.bag, slot.slot)
  ClickAuctionSellItemButton()
  ClearCursor()
  if not GetAuctionSellItemInfo() then Status(v, "The game didn't take the item: try again."); return end
  local stackPrice = d.unit * d.stackSize
  v.posting, d.started = true, 0
  W.UpdatePostButton()
  PostAuction(stackPrice, stackPrice, d.rules.duration or 1, d.stackSize, d.stacks)
  GB.Ledger.Add({ kind = "post", itemID = d.itemID, name = d.name, qty = d.stackSize * d.stacks, stacks = d.stacks,
                  stackSize = d.stackSize, price = stackPrice, unit = d.unit, duration = d.rules.duration, source = "goldboard" })
  postWatch.row, postWatch.deadline = d, GetTime() + 8 + d.stacks
  postWatch:RegisterEvent("CHAT_MSG_SYSTEM")
  postWatch:RegisterEvent("AUCTION_MULTISELL_FAILURE")
  postWatch:RegisterEvent("UI_ERROR_MESSAGE")
end

local function PostFinished(ok, why)
  local v = views.post
  postWatch:UnregisterAllEvents()
  local d = postWatch.row
  postWatch.row = nil
  v.posting = false
  if d then
    if ok then d.done = true else d.reason = why or "the post failed" end
  end
  v.table:Refresh()
  if ok then W.NextPost() else W.UpdatePostButton() end
end

postWatch:SetScript("OnEvent", function(_, event, a1, a2)
  local d = postWatch.row
  if not d then return end
  if event == "CHAT_MSG_SYSTEM" and a1 == ERR_AUCTION_STARTED then
    d.started = d.started + 1
    if d.started >= d.stacks then PostFinished(true) end
  elseif event == "AUCTION_MULTISELL_FAILURE" then
    PostFinished(d.started > 0, "stopped after " .. d.started .. " of " .. d.stacks)
  elseif event == "UI_ERROR_MESSAGE" and type(a2) == "string" and (a2 == ERR_NOT_ENOUGH_MONEY or a2:lower():find("auction")) then
    -- only auction errors stop a post (a "not enough rage" from a keybind mustn't)
    PostFinished(false, a2)
  end
end)
postWatch:SetScript("OnUpdate", function()
  if postWatch.row and GetTime() > postWatch.deadline then PostFinished(postWatch.row.started > 0, "no answer from the server") end
end)

---------------------------------------------------------------------------
-- Cancel: your auctions that someone undercut, one cancel per click
---------------------------------------------------------------------------

local function BuildCancel(p)
  local v = CreateFrame("Frame", nil, p)
  v:SetAllPoints()
  v.scan = UI.Button(v, "Scan my auctions", 150, 24)
  v.scan:SetPoint("TOPLEFT", 12, -10)
  v.status = UI.Text(v, 12, "muted", "RIGHT")
  v.status:SetPoint("TOPRIGHT", -14, -16)
  v.status:SetWidth(300)
  v.info = UI.Text(v, 12, "muted")
  v.info:SetPoint("TOPLEFT", 14, -44)
  v.info:SetWidth(WIDTH - 28)
  v.info:SetText("Your auctions where someone is now cheaper. Ones with a bid, or where the cheaper price is under your group's minimum, are kept.")
  v.table = UI.Table(v, {
    { key = "name", label = "Item", width = 0, render = function(d) return UI.ItemText(d.itemID, d.name) end },
    { key = "count", label = "Stack", width = 50, align = "RIGHT" },
    { key = "unit", label = "Yours", width = 92, align = "RIGHT", render = function(d) return UI.Money(d.unit) end },
    { key = "lowest", label = "Cheapest other", width = 100, align = "RIGHT", render = function(d) return d.lowest and UI.Money(d.lowest) or "-" end },
    { key = "action", label = "", width = 150, render = function(d)
        if d.done then return UI.Color("muted", "cancelled") end
        return d.cancel and UI.Color("sell", "cancel: undercut") or UI.Color("muted", d.why or "") end },
  }, { sortKey = "order", sortDir = 1, onEnter = function(row, d) UI.ItemTooltip(row, d.itemID) end })
  v.table:SetPoint("TOPLEFT", 10, -64); v.table:SetPoint("BOTTOMRIGHT", -10, 48)
  v.cancel = UI.Button(v, "Cancel", 260, 28, "primary")
  v.cancel:SetPoint("BOTTOMRIGHT", -10, 12)
  v.cancel:Disable()
  v.scan:SetScript("OnClick", function() W.ScanCancel() end)
  v.cancel:SetScript("OnClick", function() W.CancelNext() end)
  return v
end

local ownedWait = CreateFrame("Frame")
function W.ScanCancel()
  local v = views.cancel
  Status(v, "reading your auctions...")
  ownedWait:RegisterEvent("AUCTION_OWNED_LIST_UPDATE")
  if GetOwnerAuctionItems then GetOwnerAuctionItems() else ownedWait:GetScript("OnEvent")() end
end

ownedWait:SetScript("OnEvent", function()
  ownedWait:UnregisterAllEvents()
  local v = views.cancel
  local rows, items = {}, {}
  for i = 1, GetNumAuctionItems("owner") do
    local name, _, count, _, _, _, _, _, _, buyout, bidAmount, _, _, _, _, saleStatus, itemID = GetAuctionItemInfo("owner", i)
    if name and count and count > 0 and buyout and buyout > 0 and saleStatus ~= 1 then
      local row = { itemID = itemID, name = name, count = count, buyout = buyout, unit = buyout / count, bid = bidAmount or 0, order = #rows + 1 }
      rows[#rows + 1] = row
      items[itemID] = items[itemID] or name
    end
  end
  v.table:SetData(rows, "You have no auctions up.")
  local pending = 0
  for itemID, name in pairs(items) do
    pending = pending + 1
    local function Judge(r)
      pending = pending - 1
      local _, rules = GB.Groups.ForItem(itemID)
      local prices = rules and GB.Groups.Prices(itemID, rules)
      for _, row in ipairs(rows) do
        if row.itemID == itemID then
          row.lowest = r.lowest
          if row.bid > 0 then row.why = "has a bid: keep"
          elseif not r.lowest or r.lowest >= row.unit then row.why = "still cheapest"
          elseif prices and r.lowest < prices.min then row.why = "undercut below your minimum: keep"
          else row.cancel = true end
        end
      end
      v.table:Refresh()
      Status(v, pending > 0 and ("checking " .. pending .. " more...") or "check done")
      W.UpdateCancelButton()
    end
    local cached = GB.Query.cache[itemID]
    if cached and time() - cached.time < 120 then Judge(cached) else GB.Query.Search(itemID, name, Judge) end
  end
  Status(v, pending > 0 and ("checking " .. pending .. " items...") or "")
  W.UpdateCancelButton()
end)

function W.UpdateCancelButton()
  local v = views.cancel
  v.next = nil
  for _, d in ipairs(v.table.data) do if d.cancel and not d.done then v.next = d break end end
  v.table:Select(v.next)
  if v.next then
    v.cancel:SetLabel(string.format("Cancel %s x%d", v.next.name, v.next.count))
    v.cancel:Enable()
  else
    v.cancel:SetLabel("Cancel")
    v.cancel:Disable()
  end
end

function W.CancelNext()
  local v = views.cancel
  local d = v.next
  if not d then return end
  for i = 1, GetNumAuctionItems("owner") do
    local _, _, count, _, _, _, _, _, _, buyout, bidAmount, _, _, _, _, saleStatus, itemID = GetAuctionItemInfo("owner", i)
    if itemID == d.itemID and count == d.count and buyout == d.buyout and (bidAmount or 0) == 0 and saleStatus ~= 1 then
      CancelAuction(i)
      d.done = true
      v.table:Refresh()
      W.UpdateCancelButton()
      return
    end
  end
  d.done, d.cancel, d.why = true, false, "not found any more"
  v.table:Refresh()
  W.UpdateCancelButton()
end

---------------------------------------------------------------------------
-- The window
---------------------------------------------------------------------------

local function Build()
  win = CreateFrame("Frame", "GoldBoardAHWindow", AuctionFrame or UIParent)
  win:SetSize(WIDTH, HEIGHT)
  win:SetFrameStrata("HIGH")
  win:EnableMouse(true)
  UI.Bg(win, UI.C.bg)
  UI.Border(win)
  local head = CreateFrame("Frame", nil, win)
  head:SetPoint("TOPLEFT"); head:SetPoint("TOPRIGHT")
  head:SetHeight(34)
  local coin = head:CreateTexture(nil, "ARTWORK")
  coin:SetTexture("Interface\\MoneyFrame\\UI-GoldIcon")
  coin:SetSize(14, 14)
  coin:SetPoint("LEFT", 12, 0)
  local title = UI.Text(head, 15, "ink", "LEFT", UI.FONT_TITLE)
  title:SetPoint("LEFT", coin, "RIGHT", 8, 0)
  title:SetText("Gold Board")
  win.sub = UI.Text(head, 12, "muted", "RIGHT")
  win.sub:SetPoint("RIGHT", -12, 0)
  local rule = win:CreateTexture(nil, "BORDER")
  UI.Fill(rule, UI.C.line)
  rule:SetHeight(1)
  rule:SetPoint("TOPLEFT", 0, -62); rule:SetPoint("TOPRIGHT", 0, -62)

  local body = CreateFrame("Frame", nil, win)
  body:SetPoint("TOPLEFT", 0, -63); body:SetPoint("BOTTOMRIGHT")
  views.shop, views.post, views.cancel = BuildShop(body), BuildPost(body), BuildCancel(body)
  tabs = UI.Tabs(win, { { key = "shop", label = "Shop" }, { key = "post", label = "Post" }, { key = "cancel", label = "Cancel" } }, function(key)
    for k, view in pairs(views) do view:SetShown(k == key) end
    GB.db.settings.ahTab = key
  end)
  tabs:SetPoint("TOPLEFT", 8, -34)
  tabs:SetPoint("TOPRIGHT", -8, -34)
end

local function Place()
  win:SetParent(AuctionFrame or UIParent)
  win:ClearAllPoints()
  if AuctionFrame then win:SetPoint("TOPLEFT", AuctionFrame, "TOPRIGHT", 6, -10) else win:SetPoint("CENTER") end
end

function W.Toggle()
  if not win then Build() end
  if win:IsShown() then win:Hide(); GB.db.settings.ahWindow = false
  else Place(); win:Show(); GB.db.settings.ahWindow = true; W.OnShow() end
end

function W.OnShow()
  win.sub:SetText(GB.Signals.Describe())
  tabs:Select(GB.db.settings.ahTab or "shop")
  if views.shop:IsShown() and not views.shop.item then W.ShowDeals() end
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("AUCTION_HOUSE_SHOW")
ev:RegisterEvent("AUCTION_HOUSE_CLOSED")
ev:SetScript("OnEvent", function(_, event)
  if event == "AUCTION_HOUSE_SHOW" then
    GB.Ledger.RefreshHoldings()
    if not win then Build() end
    -- a button on the auction house to bring the window back after closing it
    if AuctionFrame and not W.toggle then
      W.toggle = UI.Button(AuctionFrame, "Gold Board", 96, 22)
      W.toggle:SetPoint("TOPRIGHT", AuctionFrame, "TOPRIGHT", -30, -14)
      W.toggle:SetFrameStrata("HIGH")
      W.toggle:SetScript("OnClick", W.Toggle)
    end
    if GB.db.settings.ahWindow ~= false then Place(); win:Show(); W.OnShow() end
  elseif win then
    win:Hide()
  end
end)
