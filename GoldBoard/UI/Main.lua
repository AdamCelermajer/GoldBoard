-- The /gb window: Overview (gold over time and the week at a glance), Deals (what's worth buying and when),
-- What I hold (what it would make now and when to sell it) and Ledger (every trade).

local _, GB = ...
local UI = GB.UI
local M = {}
GB.Main = M

local WIDTH, HEIGHT = 820, 540
local win, tabs, views = nil, nil, {}

---------------------------------------------------------------------------
-- Numbers from the ledger
---------------------------------------------------------------------------

local KIND = { buy = "Bought", sell = "Sold", post = "Posted", cancel = "Cancelled", expire = "Expired" }

-- per item: buys matched to sales oldest first; what's left is held, at what cost
local function Trades()
  local per = {}
  for _, e in ipairs(GB.db.ledger) do
    local id = e.itemID or e.name
    if id then
      local p = per[id]
      if not p then p = { itemID = e.itemID, name = e.name, lots = {}, bought = 0, cost = 0, sold = 0, proceeds = 0, realized = 0 }; per[id] = p end
      if e.kind == "buy" and (e.qty or 0) > 0 then
        p.lots[#p.lots + 1] = { qty = e.qty, unit = (e.price or 0) / e.qty }
        p.bought, p.cost = p.bought + e.qty, p.cost + (e.price or 0)
      elseif e.kind == "sell" then
        local proceeds = (e.price or 0) - (e.cut or 0)
        p.sold, p.proceeds = p.sold + (e.qty or 0), p.proceeds + proceeds
        local left, basis, matched = e.qty or 0, 0, 0
        while left > 0 and #p.lots > 0 do
          local take = math.min(left, p.lots[1].qty)
          basis, matched = basis + take * p.lots[1].unit, matched + take
          p.lots[1].qty, left = p.lots[1].qty - take, left - take
          if p.lots[1].qty <= 0 then table.remove(p.lots, 1) end
        end
        if matched > 0 then p.realized = p.realized + proceeds * matched / (e.qty or matched) - basis end
      end
    end
  end
  for _, p in pairs(per) do
    p.held, p.heldCost = 0, 0
    for _, l in ipairs(p.lots) do p.held, p.heldCost = p.held + l.qty, p.heldCost + l.qty * l.unit end
    p.avg = p.held > 0 and p.heldCost / p.held or nil
    local h = p.itemID and GB.db.holdings[p.itemID]
    if h and p.held > 0 then p.held = math.min(p.held, h) end
    local s = p.itemID and GB.Signals.Get(p.itemID)
    -- what you could sell at now: the cheapest listing, never above what it usually sells for
    p.now = s and s.sell and (((s.minBuy or 0) > 0) and math.min(s.sell, s.minBuy) or s.sell) or nil
    p.gain = (p.avg and p.now) and (p.now * 0.95 - p.avg) / p.avg or nil
  end
  return per
end
M.Trades = Trades

local function GoldTotal()
  local events = {}
  for name, c in pairs(GB.db.chars) do
    for _, s in ipairs(c.gold or {}) do events[#events + 1] = { s[1], name, s[2] } end
  end
  table.sort(events, function(a, b) return a[1] < b[1] end)
  local last, out = {}, {}
  for _, e in ipairs(events) do
    last[e[2]] = e[3]
    local total = 0
    for _, v in pairs(last) do total = total + v end
    out[#out + 1] = { e[1], total }
  end
  return out
end

---------------------------------------------------------------------------
-- Overview
---------------------------------------------------------------------------

local function Stat(parent, label)
  local f = CreateFrame("Frame", nil, parent)
  f:SetSize(180, 54)
  f.label = UI.Text(f, 12, "muted")
  f.label:SetPoint("TOPLEFT")
  f.label:SetText(label)
  f.value = UI.Text(f, 20, "ink")
  f.value:SetPoint("TOPLEFT", 0, -18)
  return f
end

local function BuildOverview(p)
  local v = CreateFrame("Frame", nil, p)
  v:SetAllPoints()
  v.stats = {}
  for i, label in ipairs({ "Gold now, all characters", "Bought, last 7 days", "Sold after the cut, 7 days", "Trading profit, all time" }) do
    local s = Stat(v, label)
    s:SetPoint("TOPLEFT", 18 + (i - 1) * 198, -16)
    v.stats[i] = s
  end
  local rule = v:CreateTexture(nil, "BORDER")
  UI.Fill(rule, UI.C.brass)
  rule:SetHeight(2)
  rule:SetPoint("TOPLEFT", 16, -78); rule:SetPoint("TOPRIGHT", -16, -78)
  v.line = UI.Text(v, 13, "ink")
  v.line:SetPoint("TOPLEFT", 18, -90)
  v.line:SetWidth(WIDTH - 36)
  v.line:SetWordWrap(true)

  v.chart = CreateFrame("Frame", nil, v)
  v.chart:SetPoint("TOPLEFT", 16, -130); v.chart:SetPoint("BOTTOMRIGHT", -16, 16)
  UI.Bg(v.chart, UI.C.panel)
  UI.Border(v.chart)
  v.chartTitle = UI.Text(v.chart, 13, "muted")
  v.chartTitle:SetPoint("TOPLEFT", 12, -10)
  v.chartTitle:SetText("Gold over time, all characters")
  v.lines, v.labels = {}, {}
  return v
end

local function DrawGold(v)
  local c = v.chart
  for _, l in ipairs(v.lines) do l:Hide() end
  for _, l in ipairs(v.labels) do l:Hide() end
  local pts = GoldTotal()
  if #pts < 2 then
    v.labels[1] = v.labels[1] or UI.Text(c, 13, "muted", "CENTER")
    v.labels[1]:ClearAllPoints()
    v.labels[1]:SetPoint("CENTER")
    v.labels[1]:SetText("The graph starts after your gold changes a couple of times.")
    v.labels[1]:Show()
    return
  end
  local L, R, T, B = 70, 16, 34, 26
  local W, H = c:GetWidth() - L - R, c:GetHeight() - T - B
  if W <= 0 or H <= 0 then C_Timer.After(0.05, function() DrawGold(v) end) return end   -- not laid out yet
  local x0, x1 = pts[1][1], pts[#pts][1]
  local lo, hi = math.huge, 0
  for _, p in ipairs(pts) do lo, hi = math.min(lo, p[2]), math.max(hi, p[2]) end
  lo, hi = lo * 0.97, hi * 1.03 + 1
  local function X(t) return L + (t - x0) / math.max(1, x1 - x0) * W end
  local function Y(g) return B + (g - lo) / (hi - lo) * H end
  local n = 0
  local function Seg(ax, ay, bx, by, color, thick)
    n = n + 1
    local l = v.lines[n] or c:CreateLine(nil, "ARTWORK")
    v.lines[n] = l
    l:SetColorTexture(color[1], color[2], color[3], color[4] or 1)
    l:SetThickness(thick or 2)
    l:SetStartPoint("BOTTOMLEFT", c, ax, ay)
    l:SetEndPoint("BOTTOMLEFT", c, bx, by)
    l:Show()
  end
  local ln = 0
  local function Label(text, x, y, justify)
    ln = ln + 1
    local fs = v.labels[ln] or UI.Text(c, 11, "muted", justify)
    v.labels[ln] = fs
    fs:ClearAllPoints()
    fs:SetPoint(justify == "RIGHT" and "RIGHT" or "CENTER", c, "BOTTOMLEFT", x, y)
    fs:SetText(text)
    fs:Show()
  end
  for i = 0, 3 do
    local g = lo + (hi - lo) * i / 3
    Seg(L, Y(g), L + W, Y(g), UI.C.line, 1)
    Label(UI.Money(g, { short = true }), L - 6, Y(g), "RIGHT")
  end
  Label(date("%a %H:%M", x0), L + 30, 12)
  Label(date("%a %H:%M", x1), L + W - 30, 12)
  -- gold moves in steps
  for i = 2, #pts do
    local a, b = pts[i - 1], pts[i]
    Seg(X(a[1]), Y(a[2]), X(b[1]), Y(a[2]), UI.C.brass, 2)
    Seg(X(b[1]), Y(a[2]), X(b[1]), Y(b[2]), UI.C.brass, 2)
  end
end

local function RefreshOverview()
  local v = views.overview
  local week = time() - 7 * 86400
  local spent, earned, fees = 0, 0, 0
  for _, e in ipairs(GB.db.ledger) do
    if (e.t or 0) >= week then
      if e.kind == "buy" then spent = spent + (e.price or 0)
      elseif e.kind == "sell" then earned = earned + (e.price or 0) - (e.cut or 0); fees = fees + (e.cut or 0) end
    end
  end
  local realized, heldN, heldCost, heldValue = 0, 0, 0, 0
  for _, p in pairs(Trades()) do
    realized = realized + p.realized
    if p.held > 0 then
      heldN = heldN + 1
      heldCost = heldCost + (p.avg or 0) * p.held
      heldValue = heldValue + (p.now and p.now * 0.95 * p.held or 0)
    end
  end
  local pts = GoldTotal()
  v.stats[1].value:SetText(pts[#pts] and UI.Money(pts[#pts][2], { short = true }) or UI.Money(GetMoney(), { short = true }))
  v.stats[2].value:SetText(UI.Money(spent, { short = true }))
  v.stats[3].value:SetText(UI.Money(earned, { short = true }))
  v.stats[4].value:SetText(UI.Color(realized >= 0 and "buy" or "sell", UI.Money(realized, { short = true, sign = true })))
  v.line:SetText(string.format("You hold %d item%s you bought for %s, worth about %s now after the cut. Auction house cut this week: %s. Prices: %s.",
    heldN, heldN == 1 and "" or "s", UI.Money(heldCost, { short = true }), UI.Money(heldValue, { short = true }), UI.Money(fees, { short = true }),
    GB.Signals.Describe()))
  DrawGold(v)
end

---------------------------------------------------------------------------
-- Ledger
---------------------------------------------------------------------------

local function BuildLedger(p)
  local v = CreateFrame("Frame", nil, p)
  v:SetAllPoints()
  v.filter = "all"
  v.filters = {}
  local x = 16
  for _, f in ipairs({ { "all", "Everything" }, { "buy", "Bought" }, { "sell", "Sold" }, { "post", "Posted" }, { "other", "Expired / cancelled" } }) do
    local b = UI.Button(v, f[2], #f[2] * 7 + 24, 24, "quiet")
    b:SetPoint("TOPLEFT", x, -12)
    x = x + b:GetWidth() + 6
    b:SetScript("OnClick", function() v.filter = f[1]; M.Refresh() end)
    b.key = f[1]
    v.filters[#v.filters + 1] = b
  end
  v.table = UI.Table(v, {
    { key = "t", label = "When", width = 96, render = function(d) return UI.When(d.t) end },
    { key = "kind", label = "What", width = 86, render = function(d) return KIND[d.kind] or d.kind end },
    { key = "name", label = "Item", width = 0, render = function(d) return UI.ItemText(d.itemID, d.name) end },
    { key = "qty", label = "Qty", width = 50, align = "RIGHT" },
    { key = "each", label = "Each", width = 100, align = "RIGHT", sortValue = function(d) return d.total and d.qty and d.total / d.qty or 0 end,
      render = function(d) return (d.total and d.qty and d.qty > 0) and UI.Money(d.total / d.qty) or "-" end },
    { key = "total", label = "Total", width = 110, align = "RIGHT", render = function(d) return d.total and UI.Money(d.total) or "-" end },
    { key = "char", label = "Character", width = 120, render = function(d) return UI.Color("muted", (d.char or ""):gsub("%-.*$", "")) end },
  }, { sortKey = "t", sortDir = -1, onEnter = function(row, d) UI.ItemTooltip(row, d.itemID) end })
  v.table:SetPoint("TOPLEFT", 12, -46); v.table:SetPoint("BOTTOMRIGHT", -12, 12)
  return v
end

local function RefreshLedger()
  local v = views.ledger
  local list = {}
  for _, e in ipairs(GB.db.ledger) do
    local keep = v.filter == "all" or e.kind == v.filter or (v.filter == "other" and (e.kind == "expire" or e.kind == "cancel"))
    if keep then
      local total = e.kind == "sell" and ((e.price or 0) - (e.cut or 0)) or e.price
      list[#list + 1] = { t = e.t, kind = e.kind, itemID = e.itemID, name = e.name, qty = e.qty, total = total, char = e.char }
    end
  end
  for _, b in ipairs(v.filters) do b.text:SetTextColor(unpack(b.key == v.filter and UI.C.brass or UI.C.ink)) end
  v.table:SetData(list, "Nothing recorded yet. Buys and sales at the auction house show up here, and on the Gold Board after a /reload.")
end

---------------------------------------------------------------------------
-- Inventory
---------------------------------------------------------------------------

local function BuildInventory(p)
  local v = CreateFrame("Frame", nil, p)
  v:SetAllPoints()
  v.info = UI.Text(v, 13, "muted")
  v.info:SetPoint("TOPLEFT", 18, -16)
  v.info:SetWidth(WIDTH - 36)
  v.info:SetText("What you bought at the auction house and still hold. \"Sell now\" means 30% or more over what you paid, after the cut.")
  v.table = UI.Table(v, {
    { key = "name", label = "Item", width = 0, render = function(d) return UI.ItemText(d.itemID, d.name) end },
    { key = "held", label = "Held", width = 60, align = "RIGHT" },
    { key = "avg", label = "Paid each", width = 96, align = "RIGHT", render = function(d) return UI.Money(d.avg) end },
    { key = "now", label = "Could sell at", width = 100, align = "RIGHT", render = function(d) return d.now and UI.Money(d.now) or "-" end },
    { key = "gain", label = "Gain", width = 70, align = "RIGHT", render = function(d)
        if not d.gain then return "-" end
        return UI.Color(d.gain >= 0 and "buy" or "sell", UI.Pct(d.gain)) end },
    { key = "signal", label = "Signal", width = 90, sortValue = function(d) return d.gain or -9 end, render = function(d)
        if not d.gain then return UI.Color("muted", "no price yet") end
        if d.gain >= 0.3 then return UI.Color("buy", "sell") end
        if d.gain >= 0 then return "sell or hold" end
        return UI.Color("sell", "hold") end },
    { key = "when", label = "When to sell", width = 190, sort = false, render = function(d)
        local s = d.itemID and GB.Signals.Get(d.itemID)
        local text, good = GB.Pricing.SellTiming(s)
        if not text then return UI.Color("muted", "no pattern yet") end
        if good == true then return UI.Color("buy", text) elseif good == false then return UI.Color("sell", text) end
        return text end },
  }, { sortKey = "gain", sortDir = -1, onEnter = function(row, d) UI.ItemTooltip(row, d.itemID) end })
  v.table:SetPoint("TOPLEFT", 12, -42); v.table:SetPoint("BOTTOMRIGHT", -12, 12)
  return v
end

local function RefreshInventory()
  local list = {}
  for _, p in pairs(Trades()) do if p.held > 0 then list[#list + 1] = p end end
  views.inventory.table:SetData(list, "Nothing held. Items you buy at the auction house show up here with what they'd make now.")
end

---------------------------------------------------------------------------
-- Deals: what's worth buying, checked away from the auction house
---------------------------------------------------------------------------

local function AuctionatorPrice(id)
  local api = Auctionator and Auctionator.API and Auctionator.API.v1 and Auctionator.API.v1.GetAuctionPriceByItemID
  if not api then return nil end
  local ok, p = pcall(api, "Gold Board", id)
  return ok and p or nil
end

local function BuildDeals(p)
  local v = CreateFrame("Frame", nil, p)
  v:SetAllPoints()
  v.info = UI.Text(v, 13, "muted")
  v.info:SetPoint("TOPLEFT", 18, -16)
  v.info:SetWidth(WIDTH - 36)
  v.info:SetWordWrap(true)
  v.info:SetText("Listed under its buy-below price (15% of profit left after the 5% cut), from Auctionator's last scan or the Gold Board's last TSM update. Items still falling show a red trend: wait for them to settle. Open the auction house to buy.")
  v.table = UI.Table(v, {
    { key = "name", label = "Item", width = 0, render = function(d) return UI.ItemText(d.itemID, d.name) end },
    { key = "cheapest", label = "Cheapest", width = 100, align = "RIGHT", render = function(d) return UI.Money(d.cheapest) end },
    { key = "sell", label = "Sells for", width = 100, align = "RIGHT", render = function(d) return UI.Money(d.sell) end },
    { key = "profit", label = "Profit each", width = 100, align = "RIGHT", render = function(d) return UI.Color("buy", UI.Money(d.profit, { sign = true })) end },
    { key = "trend", label = "Today", width = 56, align = "RIGHT", render = function(d)
        if not d.trend then return "-" end
        return UI.Color(d.trend <= -5 and "sell" or d.trend >= 5 and "buy" or "muted", string.format("%+d%%", d.trend)) end },
    { key = "sold", label = "Sold/day", width = 64, align = "RIGHT", render = function(d) return d.sold and string.format("%.0f", d.sold) or "-" end },
    { key = "when", label = "Best time to buy", width = 150, sort = false, render = function(d)
        if not d.when then return UI.Color("muted", "no pattern yet") end
        return d.whenGood and UI.Color("buy", d.when) or d.when end },
  }, { sortKey = "score", sortDir = -1, onEnter = function(row, d) UI.ItemTooltip(row, d.itemID) end })
  v.table:SetPoint("TOPLEFT", 12, -56); v.table:SetPoint("BOTTOMRIGHT", -12, 12)
  return v
end

local function RefreshDeals()
  local list = {}
  for id, s in pairs(GB.Signals.All()) do
    local ac = AuctionatorPrice(id)
    local cheapest = (ac and ac > 0) and ac or s.minBuy
    if cheapest and cheapest > 0 and s.buyBelow and cheapest <= s.buyBelow and (s.soldPerDay or 0) >= 1 then
      local profit = s.sell * 0.95 - cheapest
      local when, good = GB.Pricing.BuyTiming(s)
      list[#list + 1] = { itemID = id, name = C_Item.GetItemNameByID(id) or ("item " .. id), cheapest = cheapest, sell = s.sell,
        profit = profit, trend = s.trend, sold = s.soldPerDay, score = profit * math.min(s.soldPerDay, 50), when = when, whenGood = good }
    end
  end
  views.deals.table:SetData(list, "No deals at the last update. They show up here after Auctionator scans or the Gold Board refreshes (/reload).")
  -- names the game hadn't loaded yet arrive a moment later
  C_Timer.After(1.5, function()
    local changed = false
    for _, d in ipairs(list) do
      if d.name:find("^item ") then
        local n = C_Item.GetItemNameByID(d.itemID)
        if n then d.name, changed = n, true end
      end
    end
    if changed and views.deals:IsShown() then views.deals.table:Refresh() end
  end)
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------

local REFRESH = { overview = RefreshOverview, deals = RefreshDeals, inventory = RefreshInventory, ledger = RefreshLedger }

local function Build()
  win = UI.Window("GoldBoardMainWindow", WIDTH, HEIGHT, "Gold Board", "mainPos")
  UI.RestorePosition(win, "mainPos")
  local body = CreateFrame("Frame", nil, win)
  body:SetPoint("TOPLEFT", 0, -63); body:SetPoint("BOTTOMRIGHT")
  views.overview, views.deals, views.inventory, views.ledger = BuildOverview(body), BuildDeals(body), BuildInventory(body), BuildLedger(body)
  local rule = win:CreateTexture(nil, "BORDER")
  UI.Fill(rule, UI.C.line)
  rule:SetHeight(1)
  rule:SetPoint("TOPLEFT", 0, -62); rule:SetPoint("TOPRIGHT", 0, -62)
  tabs = UI.Tabs(win, { { key = "overview", label = "Overview" }, { key = "deals", label = "Deals" },
    { key = "inventory", label = "What I hold" }, { key = "ledger", label = "Ledger" } }, function(key)
    for k, view in pairs(views) do view:SetShown(k == key) end
    GB.db.settings.mainTab = REFRESH[key] and key or "overview"
    REFRESH[key]()
  end)
  tabs:SetPoint("TOPLEFT", 8, -34); tabs:SetPoint("TOPRIGHT", -8, -34)
  win:SetScript("OnShow", function()
    win.sub:SetText(GB.Signals.Describe())
    local key = GB.db.settings.mainTab
    tabs:Select(REFRESH[key] and key or "overview")
  end)
end

function M.Refresh()
  if win and win:IsShown() and tabs.selected then REFRESH[tabs.selected]() end
end

function M.Toggle()
  if not win then Build() end
  win:SetShown(not win:IsShown())
end
